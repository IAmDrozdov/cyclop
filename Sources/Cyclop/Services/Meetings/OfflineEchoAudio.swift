@preconcurrency import AVFoundation
import Foundation

/// Cleans the finished microphone track against the system track, offline.
///
/// Both tracks become 16 kHz mono with their start offsets already applied, so what follows reads
/// them with offsets of zero. The reference is a mono mix of the system track. The originals stay.
enum OfflineEchoAudio {
    struct Source {
        let url: URL
        var offsetMs: Int = 0
    }

    struct Result {
        let directory: URL
        let frames: Int64
        var microphone: URL { directory.appendingPathComponent(MeetingFile.mic) }
        var system: URL { directory.appendingPathComponent(MeetingFile.system) }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    enum ProcessingError: Error {
        case invalidSource, truncated
    }

    static func prepare(
        microphone: Source, system: Source, in directory: URL,
        cancellerFactory: () throws -> EchoCanceller = { try EchoCanceller() }
    ) throws -> Result {
        let mic = try Reader(microphone)
        let far = try Reader(system)
        let work = directory.appendingPathComponent(".aec-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let result = Result(directory: work, frames: max(mic.totalFrames, far.totalFrames))
        var completed = false
        defer { if !completed { result.remove() } }

        let canceller = try cancellerFactory()
        try warmUp(canceller, microphone: try Reader(microphone), reference: try Reader(system), frames: result.frames)
        try write(microphone: mic, reference: far, result: result, canceller: canceller)
        for url in [result.microphone, result.system] {
            guard try AVAudioFile(forReading: url).length == result.frames else { throw ProcessingError.truncated }
        }
        completed = true
        return result
    }

    /// Seconds of playback the model hears twice: once to settle, then for real. Its delay estimate locks after 3.5 s.
    static let warmUpSeconds = 4

    /// Feeds the first seconds of audible playback (silent hops skipped) to the canceller before the real pass,
    /// so the start of the meeting is cleaned as well as the rest and a short chime cannot set the delay.
    /// Nothing happens when the system track never plays.
    private static func warmUp(_ canceller: EchoCanceller, microphone: Reader, reference: Reader, frames: Int64) throws {
        let hop = EchoCanceller.frameSize
        var position: Int64 = 0, fed = 0
        while position + Int64(hop) <= frames, fed < warmUpSeconds * EchoCanceller.sampleRate {
            try Task.checkCancellation()
            let far = try reference.read(at: position, count: hop)
            let near = try microphone.read(at: position, count: hop)
            if far.contains(where: { abs($0) >= EchoCanceller.silenceFloor }) {
                try canceller.warmUp(microphone: near, reference: far)
                fed += hop
            }
            position += Int64(hop)
        }
    }

    private static func write(microphone: Reader, reference: Reader, result: Result, canceller: EchoCanceller) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let settings = AudioLevel.pcmSettings(sampleRate: 16_000, channels: 1)
        let micFile = try AVAudioFile(forWriting: result.microphone, settings: settings)
        let farFile = try AVAudioFile(forWriting: result.system, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(EchoCanceller.frameSize))!
        var pendingFrames: Int?

        func write(_ samples: [Float], count: Int, to file: AVAudioFile) throws {
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: count) }
            try file.write(from: buffer)
        }

        // Every window but the last ends on a model hop (937 hops, just under 15 s): padding between
        // windows would corrupt the model's recurrent state.
        let nominal = 15 * 16_000
        let window = nominal - nominal % EchoCanceller.frameSize
        for position in stride(from: Int64(0), to: result.frames, by: window) {
            try Task.checkCancellation()
            let count = Int(min(Int64(window), result.frames - position))
            var mic: [Float] = [], far: [Float] = []
            mic.reserveCapacity(count)
            far.reserveCapacity(count)
            for offset in stride(from: 0, to: count, by: EchoCanceller.frameSize) {
                let frames = min(EchoCanceller.frameSize, count - offset)
                mic += try microphone.read(at: position + Int64(offset), count: frames).prefix(frames)
                far += try reference.read(at: position + Int64(offset), count: frames).prefix(frames)
            }
            for offset in stride(from: 0, to: count, by: EchoCanceller.frameSize) {
                let frames = min(EchoCanceller.frameSize, count - offset)
                var local = [Float](repeating: 0, count: EchoCanceller.frameSize)
                var remote = local
                for i in 0..<frames {
                    local[i] = mic[offset + i]
                    remote[i] = far[offset + i]
                }
                try write(remote, count: frames, to: farFile)
                if let cleaned = try canceller.process(microphone: local, reference: remote) {
                    guard let previous = pendingFrames else { throw ProcessingError.truncated }
                    try write(cleaned, count: previous, to: micFile)
                }
                pendingFrames = frames
            }
        }
        if let final = try canceller.finish() {
            guard let pendingFrames else { throw ProcessingError.truncated }
            try write(final, count: pendingFrames, to: micFile)
        }
    }

    /// Sequential bounded-memory conversion to 16 kHz mono; a stereo source is mixed down.
    private final class Reader: @unchecked Sendable {
        let totalFrames: Int64
        private let start: Int64
        private let file: AVAudioFile
        private let converter: AVAudioConverter
        private let staging: AVAudioPCMBuffer
        private var readError: Error?

        init(_ source: Source) throws {
            file = try AVAudioFile(forReading: source.url)
            guard file.length > 0, source.offsetMs >= 0,
                let mono = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
                let converter = AVAudioConverter(from: file.processingFormat, to: mono),
                let staging = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)
            else { throw ProcessingError.invalidSource }
            self.converter = converter
            self.staging = staging
            start = Int64(source.offsetMs) * 16
            totalFrames = Int64((Double(file.length) * 16_000 / file.processingFormat.sampleRate).rounded()) + start
        }

        func read(at position: Int64, count: Int) throws -> [Float] {
            var samples = [Float](repeating: 0, count: count)
            let lead = Int(max(0, start - position))
            guard lead < count, position < totalFrames else { return samples }
            let wanted = Int(min(Int64(count - lead), totalFrames - max(position, start)))
            guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(wanted))
            else { throw ProcessingError.invalidSource }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { [self] _, status in
                guard file.framePosition < file.length else {
                    status.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: staging)
                    guard staging.frameLength > 0 else { throw ProcessingError.truncated }
                    status.pointee = .haveData
                    return staging
                } catch {
                    readError = error
                    status.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let error { throw error }
            guard status != .error, Int(output.frameLength) == wanted else { throw ProcessingError.truncated }
            for i in 0..<wanted { samples[lead + i] = output.floatChannelData![0][i] }
            return samples
        }
    }
}
