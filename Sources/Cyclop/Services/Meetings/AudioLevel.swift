@preconcurrency import AVFoundation
import os.lock

/// Peak level of a captured buffer, and the 16-bit PCM format both tracks are written in.
enum AudioLevel {
    /// Linear PCM, not AAC: a CAF with variable-size packets is unreadable until its
    /// packet table is written at close, so a killed app would lose the whole meeting.
    static func pcmSettings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Absolute peak across channels, 0...1; nil for a sample format not measured.
    static func peak(of buffer: AVAudioPCMBuffer) -> Float? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let channels = Int(buffer.format.channelCount)
        var peak: Float = 0
        if let data = buffer.floatChannelData {
            for channel in 0..<channels {
                for frame in 0..<frames { peak = max(peak, abs(data[channel][frame])) }
            }
            return min(peak, 1)
        }
        if let data = buffer.int16ChannelData {
            for channel in 0..<channels {
                for frame in 0..<frames {
                    peak = max(peak, abs(Float(data[channel][frame])) / 32768)
                }
            }
            return min(peak, 1)
        }
        return nil
    }
}

/// The latest peak of one track, read by the pane while it is on screen.
final class LevelGauge: @unchecked Sendable {
    private struct Reading {
        var peak: Float = 0
        var at: Date = .distantPast
        var heardSound = false
    }

    /// Roughly -40 dBFS: above a quiet room, below any speech worth transcribing.
    static let soundThreshold: Float = 0.01

    private let state = OSAllocatedUnfairLock(initialState: Reading())

    func record(_ peak: Float) {
        state.withLock {
            $0 = Reading(peak: peak, at: Date(), heardSound: $0.heardSound || peak >= Self.soundThreshold)
        }
    }

    /// Whether any buffer so far carried sound.
    var heardSound: Bool { state.withLock { $0.heardSound } }

    /// 0 when nothing arrived for a third of a second, so a stalled track reads as silent.
    var current: Float {
        state.withLock { Date().timeIntervalSince($0.at) < 0.35 ? $0.peak : 0 }
    }
}
