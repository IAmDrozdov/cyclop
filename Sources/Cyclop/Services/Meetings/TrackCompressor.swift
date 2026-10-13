@preconcurrency import AVFoundation
import Foundation

/// Writes the two tracks as one stereo AAC file: microphone left, system sound (mixed to mono) right.
enum TrackCompressor {
    enum CompressionError: Error {
        case nothingToWrite
        case unreadable(URL)
        case verificationFailed
    }

    static let sampleRate = 44_100.0
    static let chunk: AVAudioFrameCount = 44_100

    /// Streams both tracks, delays each by its start offset, writes `audio.tmp.m4a`, checks it and renames it to `output`.
    /// A missing or empty track becomes a silent channel. The sources are left alone.
    static func compress(
        mic: URL, system: URL, offsets: MeetingMeta.Offsets?, to output: URL
    ) throws {
        let left = try MonoReader(url: mic, delayMs: offsets?.mic ?? 0)
        let right = try MonoReader(url: system, delayMs: offsets?.system ?? 0)
        let total = max(left.totalFrames, right.totalFrames)
        guard total > 0 else { throw CompressionError.nothingToWrite }

        let temp = output.deletingLastPathComponent().appendingPathComponent("audio.tmp.m4a")
        try? FileManager.default.removeItem(at: temp)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false
        ) else { throw CompressionError.nothingToWrite }

        do {
            let file = try AVAudioFile(forWriting: temp, settings: settings)
            var written: AVAudioFrameCount = 0
            while Int(written) < total {
                let frames = AVAudioFrameCount(min(Int(chunk), total - Int(written)))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                    let channels = buffer.floatChannelData
                else { throw CompressionError.nothingToWrite }
                buffer.frameLength = frames
                left.fill(channels[0], frames: Int(frames))
                right.fill(channels[1], frames: Int(frames))
                try file.write(from: buffer)
                written += frames
            }
        }

        // The file object is gone, so the encoder has finalised it; read it back before trusting it.
        let check = try AVAudioFile(forReading: temp)
        guard check.fileFormat.channelCount == 2,
            Double(check.length) >= Double(total) * 0.99
        else {
            try? FileManager.default.removeItem(at: temp)
            throw CompressionError.verificationFailed
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: temp, to: output)
    }

    /// One track as mono float at the output rate, after a silent lead-in of its start offset.
    final class MonoReader {
        private let file: AVAudioFile?
        private let converter: AVAudioConverter?
        private let inFormat: AVAudioFormat?
        private let outFormat: AVAudioFormat
        private var lead: Int
        private(set) var totalFrames: Int
        private var exhausted = false

        init(url: URL, delayMs: Int) throws {
            outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: TrackCompressor.sampleRate, channels: 1, interleaved: false
            )!
            lead = max(0, Int(Double(delayMs) / 1000 * TrackCompressor.sampleRate))
            if AudioTrack.isSilentSide(url) {
                file = nil
                converter = nil
                inFormat = nil
                totalFrames = 0
                exhausted = true
                return
            }
            guard let file = try? AVAudioFile(forReading: url) else { throw CompressionError.unreadable(url) }
            self.file = file
            inFormat = file.processingFormat
            converter = AVAudioConverter(from: file.processingFormat, to: outFormat)
            totalFrames = lead + Int((Double(file.length) / file.processingFormat.sampleRate * TrackCompressor.sampleRate).rounded(.up))
        }

        /// Writes the next `frames` samples; silence once the track has run out.
        func fill(_ out: UnsafeMutablePointer<Float>, frames: Int) {
            var done = 0
            let silent = min(lead, frames)
            for i in 0..<silent { out[i] = 0 }
            lead -= silent
            done = silent
            while done < frames {
                guard !exhausted, let converter, let file, let inFormat,
                    let buffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(frames - done))
                else { break }
                var error: NSError?
                let status = converter.convert(to: buffer, error: &error) { count, inputStatus in
                    guard let chunk = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: count),
                        (try? file.read(into: chunk, frameCount: count)) != nil, chunk.frameLength > 0
                    else {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    inputStatus.pointee = .haveData
                    return chunk
                }
                if status == .endOfStream || status == .error { exhausted = true }
                let got = Int(buffer.frameLength)
                if got > 0, let data = buffer.floatChannelData {
                    for i in 0..<got { out[done + i] = data[0][i] }
                    done += got
                } else if exhausted {
                    break
                }
            }
            if done < frames { for i in done..<frames { out[i] = 0 } }
        }
    }
}
