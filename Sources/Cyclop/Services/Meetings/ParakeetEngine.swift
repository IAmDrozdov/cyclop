import Foundation
@preconcurrency import FluidAudio

/// Parakeet TDT 0.6B v3 through FluidAudio's Core ML port: multilingual, language detected by the model.
actor ParakeetEngine: SpeechEngine {
    enum EngineError: Error {
        case modelsMissing
    }

    nonisolated let engineName = "parakeet"
    nonisolated let modelName = "parakeet-tdt-0.6b-v3-coreml"
    nonisolated var modelsReady: Bool { SpeechModels.isReady }

    private var manager: AsrManager?

    /// FluidAudio re-downloads a model, and purges its cache, when a load fails. Processing must never
    /// reach the network, so the library stays offline except inside `downloadModels`.
    init() {
        ModelHub.offlineMode = true
    }

    func downloadModels(progress: @escaping @Sendable (Double) -> Void) async throws {
        ModelHub.offlineMode = false
        defer { ModelHub.offlineMode = true }
        // Recognition is about two thirds of the size, the separator the rest.
        _ = try await AsrModels.download(version: .v3) { progress($0.fractionCompleted * 0.65) }
        _ = try await SortformerModels.loadFromHuggingFace(config: SpeechModels.separationConfig) {
            progress(0.65 + $0.fractionCompleted * 0.35)
        }
        progress(1)
    }

    func voiceTurns(in audio: URL) async throws -> [VoiceTurn] {
        guard SpeechModels.isSeparationReady else { throw EngineError.modelsMissing }
        let config = SpeechModels.separationConfig
        let models = try await SortformerModels.loadFromHuggingFace(config: config)
        let diarizer = SortformerDiarizer(config: config)
        diarizer.initialize(models: models)
        let timeline = try diarizer.processComplete(audioFileURL: audio)
        return timeline.speakers.values
            .flatMap(\.finalizedSegments)
            .map { VoiceTurn(voice: "S\($0.speakerIndex)", start: Double($0.startTime), end: Double($0.endTime)) }
            .sorted { $0.start < $1.start }
    }

    /// The model settles on one language per window, so a short sentence that shares a window with
    /// another language is lost. With `splitAtPauses` each stretch of speech between pauses is
    /// recognised on its own: for the other side, whose track is clean. The microphone keeps the
    /// whole-file path, because a stretch cut out of its residual noise comes back as "Yeah.".
    func words(in audio: URL, splitAtPauses: Bool) async throws -> [TimedWord] {
        let manager = try await loadedManager()
        guard splitAtPauses else {
            var state = try TdtDecoderState()
            // No language hint: Russian, Ukrainian and English may share one meeting.
            let result = try await manager.transcribe(audio, decoderState: &state, language: nil)
            return Self.timedWords(result, offset: 0)
        }
        let samples = try AudioConverter().resampleAudioFile(audio)
        var out: [TimedWord] = []
        for span in SpeechSpans.split(samples, sampleRate: 16_000) {
            try Task.checkCancellation()
            var state = try TdtDecoderState()
            let result = try await manager.transcribe(Array(samples[span]), decoderState: &state, language: nil)
            out += Self.timedWords(result, offset: Double(span.lowerBound) / 16_000)
        }
        return out
    }

    private static func timedWords(_ result: ASRResult, offset: Double) -> [TimedWord] {
        let words = buildWordTimings(from: result.tokenTimings ?? [])
        if words.isEmpty {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [TimedWord(text: text, start: offset, end: offset + result.duration)]
        }
        return words.map { TimedWord(text: $0.word, start: $0.startTime + offset, end: $0.endTime + offset) }
    }

    /// Loads from the cache folder only; a missing model is an error, not a download.
    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        guard SpeechModels.isRecognitionReady else { throw EngineError.modelsMissing }
        let models = try await AsrModels.load(from: SpeechModels.recognitionFolder, version: .v3)
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
        return manager
    }
}

/// Stretches of a track that hold sound, split at pauses; pure, so it is tested without a model.
enum SpeechSpans {
    /// 80 ms, one encoder frame of the recogniser.
    static let frameSeconds = 0.08
    /// A pause this long ends a span.
    static let pauseSeconds = 0.4
    /// Kept around each span so a soft first or last syllable is not cut.
    static let padSeconds = 0.24
    /// The recogniser refuses anything shorter than 0.3 s.
    static let shortestSeconds = 0.5

    /// Sample ranges in order. A frame is sound when it is within 40 dB of the loud frames and
    /// above -60 dBFS; a silent track gives no spans.
    static func split(_ samples: [Float], sampleRate: Int) -> [Range<Int>] {
        let frame = Int(Double(sampleRate) * frameSeconds)
        guard frame > 0, !samples.isEmpty else { return [] }
        let levels: [Float] = stride(from: 0, to: samples.count, by: frame).map { start in
            let slice = samples[start..<min(start + frame, samples.count)]
            let power = slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)
            return 10 * log10(max(power, 1e-12))
        }
        // The reference is the 95th percentile of the frames above -60 dBFS, not the peak: one loud
        // beep must not lift the threshold over the quieter speech.
        let audible = levels.filter { $0 > -60 }.sorted()
        guard !audible.isEmpty else { return [] }
        let loud = audible[min(audible.count - 1, audible.count * 95 / 100)]
        let threshold = max(loud - 40, -60)
        let pauseFrames = Int((pauseSeconds / frameSeconds).rounded())
        let padFrames = Int((padSeconds / frameSeconds).rounded())

        var frames: [Range<Int>] = []
        var start: Int?, lastSound = 0
        for (index, level) in levels.enumerated() where level >= threshold {
            if let open = start, index - lastSound > pauseFrames {
                frames.append(open..<lastSound + 1)
                start = index
            } else if start == nil {
                start = index
            }
            lastSound = index
        }
        if let open = start { frames.append(open..<lastSound + 1) }

        let shortest = Int(Double(sampleRate) * shortestSeconds)
        return frames.map { span in
            var lower = max(0, (span.lowerBound - padFrames) * frame)
            var upper = min(samples.count, (span.upperBound + padFrames) * frame)
            if upper - lower < shortest {
                let missing = shortest - (upper - lower)
                lower = max(0, lower - missing / 2)
                upper = min(samples.count, lower + shortest)
            }
            return lower..<upper
        }
    }
}
