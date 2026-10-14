@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import Cyclop

/// Сжатие дорожек в один стерео-файл проверяется на настоящих сгенерированных CAF.
struct TrackCompressorTests {
    private static func folder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cyclop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Тон заданной частоты и длины в 16-битном PCM, как пишут рекордеры.
    private static func tone(_ url: URL, seconds: Double, rate: Double, channels: AVAudioChannelCount, amplitude: Float) throws {
        let file = try AVAudioFile(
            forWriting: url, settings: AudioLevel.pcmSettings(sampleRate: rate, channels: channels),
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for i in 0..<Int(frames) {
                buffer.floatChannelData![channel][i] = amplitude * sin(Float(i) * 0.05)
            }
        }
        try file.write(from: buffer)
    }

    @Test func twoTracksBecomeOneStereoFileAndOnlyThenTheOriginalsGo() throws {
        let dir = try Self.folder()
        try Self.tone(dir.appendingPathComponent(MeetingFile.mic), seconds: 2, rate: 48_000, channels: 1, amplitude: 0.5)
        try Self.tone(dir.appendingPathComponent(MeetingFile.system), seconds: 2, rate: 44_100, channels: 2, amplitude: 0.5)

        try MeetingPipeline.compressAudio(in: dir, offsets: .init(mic: 0, system: 500))

        let audio = dir.appendingPathComponent(MeetingFile.audio)
        let file = try AVAudioFile(forReading: audio)
        #expect(file.fileFormat.channelCount == 2)
        // 2 с + 0,5 с сдвига системной дорожки.
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 2.5) < 0.1)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(MeetingFile.mic).path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.tmp.m4a").path))
    }

    @Test func keepTracksLeavesTheOriginalsBesideTheCompressedFile() throws {
        let dir = try Self.folder()
        try Self.tone(dir.appendingPathComponent(MeetingFile.mic), seconds: 1, rate: 48_000, channels: 1, amplitude: 0.5)
        try Self.tone(dir.appendingPathComponent(MeetingFile.system), seconds: 1, rate: 48_000, channels: 2, amplitude: 0.5)

        try MeetingPipeline.compressAudio(in: dir, offsets: nil, keepTracks: true)

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(MeetingFile.audio).path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(MeetingFile.mic).path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(MeetingFile.system).path))
    }

    @Test func aMissingTrackBecomesASilentChannel() throws {
        let dir = try Self.folder()
        try Self.tone(dir.appendingPathComponent(MeetingFile.mic), seconds: 1, rate: 48_000, channels: 1, amplitude: 0.5)

        try MeetingPipeline.compressAudio(in: dir, offsets: nil)

        let file = try AVAudioFile(forReading: dir.appendingPathComponent(MeetingFile.audio))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 20_000)!
        try file.read(into: buffer)
        let right = (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![1][$0]) }.max() ?? 1
        let left = (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
        #expect(right < 0.01)
        #expect(left > 0.1)
    }

    @Test func aFailedCompressionKeepsTheOriginals() throws {
        let dir = try Self.folder()
        try Data("not audio".utf8).write(to: dir.appendingPathComponent(MeetingFile.mic))

        #expect(throws: (any Error).self) { try MeetingPipeline.compressAudio(in: dir, offsets: nil) }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(MeetingFile.mic).path))
    }
}
