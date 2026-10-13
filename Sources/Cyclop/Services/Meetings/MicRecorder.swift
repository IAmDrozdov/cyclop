@preconcurrency import AVFoundation
import Foundation
import os.lock

/// Records the default microphone, mixed down to mono, to a file.
///
/// Plugging in headphones changes the input device: the engine is rebuilt on the new one and the
/// span nothing was captured is written as silence once the first new buffer arrives, so the track
/// stays in step with the clock and the other track.
final class MicRecorder: @unchecked Sendable {
    enum RecorderError: Error {
        case noInput
        case fileCreationFailed(Error)
        case engineStartFailed(Error)
    }

    /// Gaps shorter than this are not worth padding.
    static let shortestGap: TimeInterval = 0.05

    let gauge = LevelGauge()

    private var engine = AVAudioEngine()
    private var isRecording = false
    private var changeObserver: NSObjectProtocol?
    private var fileFormat: AVAudioFormat?

    private struct Shared {
        var file: AVAudioFile?
        var converter: AVAudioConverter?
        var firstBufferAt: Date?
        /// When the last buffer before a device change ended; set until the first one after it lands.
        var gapFrom: Date?
        var lastBufferEnd: Date?
    }
    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    var firstBufferAt: Date? { shared.withLock { $0.firstBufferAt } }

    func start(writingTo url: URL) throws {
        guard !isRecording else { return }

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                channels: 1, interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: monoFormat)
        else { throw RecorderError.noInput }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: AudioLevel.pcmSettings(sampleRate: inputFormat.sampleRate, channels: 1),
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }
        fileFormat = monoFormat
        shared.withLock { $0 = Shared(file: file, converter: converter) }

        try attach(inputFormat: inputFormat)
        isRecording = true
        changeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.deviceChanged() }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        shared.withLock { $0.file = nil }
    }

    private func attach(inputFormat: AVAudioFormat) throws {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.write(buffer)
        }
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            shared.withLock { $0.file = nil }
            throw RecorderError.engineStartFailed(error)
        }
    }

    /// The input device changed: rebuild the tap on the new format, converting into the file's own format.
    private func deviceChanged() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        shared.withLock { $0.gapFrom = $0.gapFrom ?? $0.lastBufferEnd ?? Date() }
        rebuild(attempt: 0)
    }

    /// A headset switching profiles can report no input for a moment, so the rebuild is retried for ten seconds.
    private func rebuild(attempt: Int) {
        guard isRecording, let fileFormat else { return }
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        if inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
            let converter = AVAudioConverter(from: inputFormat, to: fileFormat)
        {
            shared.withLock { $0.converter = converter }
            if (try? attach(inputFormat: inputFormat)) != nil { return }
        }
        guard attempt < 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.rebuild(attempt: attempt + 1)
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let fileFormat else { return }
        let now = Date()
        let (file, converter, gap): (AVAudioFile?, AVAudioConverter?, TimeInterval) = shared.withLock { state in
            if state.firstBufferAt == nil { state.firstBufferAt = now }
            var gap: TimeInterval = 0
            if let from = state.gapFrom {
                gap = now.timeIntervalSince(from) - Double(buffer.frameLength) / buffer.format.sampleRate
                state.gapFrom = nil
            }
            return (state.file, state.converter, gap)
        }
        guard let file, let converter,
            let mono = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: buffer.frameLength * 4 + 4096)
        else { return }

        let supplied = Flag()
        var error: NSError?
        converter.convert(to: mono, error: &error) { _, status in
            if supplied.raised {
                status.pointee = .noDataNow
                return nil
            }
            supplied.raised = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, mono.frameLength > 0 else { return }

        if gap > Self.shortestGap { writeSilence(seconds: gap, to: file, format: fileFormat) }
        if let peak = AudioLevel.peak(of: mono) { gauge.record(peak) }
        try? file.write(from: mono)
        let end = now.addingTimeInterval(Double(mono.frameLength) / fileFormat.sampleRate)
        shared.withLock { $0.lastBufferEnd = end }
    }

    private func writeSilence(seconds: TimeInterval, to file: AVAudioFile, format: AVAudioFormat) {
        var remaining = AVAudioFrameCount(seconds * format.sampleRate)
        while remaining > 0 {
            let frames = min(remaining, 16_384)
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            silence.frameLength = frames
            memset(silence.floatChannelData![0], 0, Int(frames) * MemoryLayout<Float>.size)
            try? file.write(from: silence)
            remaining -= frames
        }
    }
}

/// Lets the converter's input block hand over its one buffer exactly once.
private final class Flag: @unchecked Sendable {
    var raised = false
}
