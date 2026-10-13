import Foundation

/// Turns the two tracks of one meeting folder into `transcript.md`, then `transcript.json`.
struct MeetingPipeline: Sendable {
    let engine: SpeechEngine
    /// Tests point this at a built library instead of the app bundle.
    var cancellerFactory: @Sendable () throws -> EchoCanceller = { try EchoCanceller() }

    func process(folder: URL, meta: MeetingMeta, title: String, now: Date = Date()) async throws {
        let micURL = folder.appendingPathComponent(MeetingFile.mic)
        let systemURL = folder.appendingPathComponent(MeetingFile.system)

        // With both sides present the microphone is cleaned against the system track first.
        // Any failure here, a missing library included, falls through to the raw tracks.
        var offsets = meta.startOffsetMs
        var micIn = micURL, systemIn = systemURL
        var cleaned: OfflineEchoAudio.Result?
        if !AudioTrack.isSilentSide(micURL), !AudioTrack.isSilentSide(systemURL) {
            do {
                let result = try OfflineEchoAudio.prepare(
                    microphone: .init(url: micURL, offsetMs: meta.startOffsetMs?.mic ?? 0),
                    system: .init(url: systemURL, offsetMs: meta.startOffsetMs?.system ?? 0),
                    in: folder,
                    cancellerFactory: cancellerFactory
                )
                cleaned = result
                micIn = result.microphone
                systemIn = result.system
                offsets = nil  // already applied
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                NSLog("Meetings: echo cancellation skipped, raw tracks used: \(error)")
            }
        }
        defer { cleaned?.remove() }

        let mic = try await words(in: micIn, splitAtPauses: false)
        try Task.checkCancellation()
        let system = try await words(in: systemIn, splitAtPauses: true)
        try Task.checkCancellation()
        // Separation failing alone still leaves a transcript with the unlettered other side.
        let turns = system.isEmpty ? [] : (try? await engine.voiceTurns(in: systemIn)) ?? []
        try Task.checkCancellation()

        let assembled = TranscriptAssembly.assemble(mic: mic, system: system, offsets: offsets, turns: turns)
        var lines = cleaned != nil
            ? EchoFilter.dropResidualEchoes(assembled) : EchoFilter.dropEchoes(assembled)
        // The canceller can pass loud playback through as if it were the owner; the audio decides those lines.
        if let cleaned {
            lines = PlaybackEcho.dropPlayback(lines, microphone: cleaned.microphone, system: cleaned.system)
        }
        let markdown = TranscriptAssembly.markdown(title: title, lines: lines) { line in
            switch line.speaker {
            case .me: return localized("Me")
            case .other:
                return line.voiceLetter.map { localized("Speaker %@", $0) } ?? localized("Speaker")
            }
        }
        try Data(markdown.utf8).write(
            to: folder.appendingPathComponent(MeetingFile.transcript), options: .atomic
        )
        let file = TranscriptFile(
            engine: engine.engineName, model: engine.modelName, createdAt: now, segments: lines
        )
        try MeetingMeta.encoder.encode(file).write(
            to: folder.appendingPathComponent(MeetingFile.transcriptData), options: .atomic
        )
        // The transcript is already on disk: a failed compression costs neither text nor audio.
        try? Self.compressAudio(in: folder, offsets: meta.startOffsetMs)
    }

    /// A track with no frames is a silent side and never reaches the recogniser.
    private func words(in url: URL, splitAtPauses: Bool) async throws -> [TimedWord] {
        guard FileManager.default.fileExists(atPath: url.path), !AudioTrack.isSilentSide(url) else {
            return []
        }
        return try await engine.words(in: url, splitAtPauses: splitAtPauses)
    }

    /// Compresses the two tracks into `audio.m4a` and only then removes them. A failure keeps the originals.
    static func compressAudio(in folder: URL, offsets: MeetingMeta.Offsets?) throws {
        let mic = folder.appendingPathComponent(MeetingFile.mic)
        let system = folder.appendingPathComponent(MeetingFile.system)
        try TrackCompressor.compress(
            mic: mic, system: system, offsets: offsets,
            to: folder.appendingPathComponent(MeetingFile.audio)
        )
        try? FileManager.default.removeItem(at: mic)
        try? FileManager.default.removeItem(at: system)
    }
}
