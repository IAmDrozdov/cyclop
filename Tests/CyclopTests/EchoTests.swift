@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import Cyclop

/// Эхоподавитель на настоящей библиотеке, если она собрана (`.build/localvqe`), и текстовые фильтры.
struct EchoTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let localvqe = root.appendingPathComponent(".build/localvqe")

    /// Бандл-обманка: ссылки на собранную библиотеку и модель в раскладке настоящего приложения.
    private static func fakeBundle() throws -> URL {
        let bundle = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cyclop-tests-\(UUID().uuidString).app", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents/Frameworks"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents/Resources/Models"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: bundle.appendingPathComponent("Contents/Frameworks/liblocalvqe.dylib"),
            withDestinationURL: localvqe.appendingPathComponent("lib/liblocalvqe.dylib"))
        try fm.createSymbolicLink(
            at: bundle.appendingPathComponent("Contents/Resources/Models/\(LocalVQEAssets.modelName)"),
            withDestinationURL: localvqe.appendingPathComponent("model/\(LocalVQEAssets.modelName)"))
        return bundle
    }

    private static func write(_ url: URL, rate: Double, channels: AVAudioChannelCount, seconds: Double, sample: (Int) -> Float) throws {
        let file = try AVAudioFile(
            forWriting: url, settings: AudioLevel.pcmSettings(sampleRate: rate, channels: channels),
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for i in 0..<Int(frames) { buffer.floatChannelData![channel][i] = sample(i) }
        }
        try file.write(from: buffer)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: localvqe.appendingPathComponent("lib/liblocalvqe.dylib").path)))
    func theRealLibraryCleansTwoTracksAndKeepsThemTheSameLength() throws {
        let bundle = try Self.fakeBundle()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cyclop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mic = dir.appendingPathComponent("m.caf"), system = dir.appendingPathComponent("s.caf")
        // Эхо в чистом виде: микрофон слышит то же, что играет система.
        try Self.write(mic, rate: 48_000, channels: 1, seconds: 3) { 0.3 * sin(Float($0) * 0.07) }
        try Self.write(system, rate: 44_100, channels: 2, seconds: 3) { 0.3 * sin(Float($0) * 0.075) }

        let result = try OfflineEchoAudio.prepare(
            microphone: .init(url: mic, offsetMs: 0), system: .init(url: system, offsetMs: 500), in: dir,
            cancellerFactory: { try EchoCanceller(bundle: bundle) })

        let cleaned = try AVAudioFile(forReading: result.microphone)
        let reference = try AVAudioFile(forReading: result.system)
        #expect(cleaned.length == reference.length)
        // 3 с + 0,5 с сдвига системной дорожки, в 16 кГц.
        #expect(abs(Double(cleaned.length) / 16_000 - 3.5) < 0.1)
    }

    @Test func aMissingLibraryIsAnErrorTheCallerCanFallBackFrom() {
        let nowhere = URL(fileURLWithPath: "/nonexistent.app")
        #expect(throws: (any Error).self) { try EchoCanceller(bundle: nowhere) }
    }

    // MARK: - Начало воспроизведения

    /// Считает вызовы модели и отдаёт нули.
    private final class CountingBackend: EchoCancellationBackend {
        let sampleRate = 16_000
        let hopSize = 256
        var calls = 0
        func process(microphone: [Float], reference: [Float]) throws -> [Float] {
            calls += 1
            return [Float](repeating: 0, count: hopSize)
        }
    }

    @Test func theModelHearsNothingBeforePlaybackStarts() throws {
        let backend = CountingBackend()
        let canceller = try EchoCanceller(backend: backend)
        let mic = [Float](repeating: 0.1, count: 256)
        // Остаток кодека или ресемплера ниже −80 дБFS — ещё не звук: оценка задержки защёлкнулась бы на тишине.
        let residue = [Float](repeating: 1e-6, count: 256)
        let playback = [Float](repeating: 0.2, count: 256)
        #expect(try canceller.process(microphone: mic, reference: residue) == nil)
        #expect(try canceller.process(microphone: mic, reference: residue) == mic)
        #expect(backend.calls == 0)
        // Первый хоп с воспроизведением доходит до модели, а предыдущий хоп выходит нетронутым.
        #expect(try canceller.process(microphone: mic, reference: playback) == mic)
        #expect(backend.calls == 1)
        #expect(try canceller.process(microphone: mic, reference: playback) == [Float](repeating: 0, count: 256))
    }

    @Test func warmUpFeedsTheModelAndGivesNothingBack() throws {
        let backend = CountingBackend()
        let canceller = try EchoCanceller(backend: backend)
        let hop = [Float](repeating: 0.2, count: 256)
        try canceller.warmUp(microphone: hop, reference: hop)
        try canceller.warmUp(microphone: hop, reference: hop)
        #expect(backend.calls == 2)
        #expect(try canceller.process(microphone: hop, reference: hop) == nil)
        #expect(throws: (any Error).self) { try canceller.warmUp(microphone: hop, reference: hop) }
    }

    // MARK: - Воспроизведение, узнанное по звуку

    /// Детерминированный шум вместо речи.
    private static func noise(_ count: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 20_000) / 100_000 - 0.1
        }
    }

    @Test func coherenceTellsPlaybackFromTheOwner() {
        let lead = PlaybackEcho.maxDelayHops * PlaybackEcho.hop
        let count = 32_000
        let system = Self.noise(count + lead, seed: 1)
        // Эхо: системная дорожка на 150 мс позже и тише.
        let echo = (0..<count).map { 0.5 * system[lead + $0 - 2_400] }
        let own = Self.noise(count, seed: 2)
        let both = zip(echo, own).map { $0 + $1 }
        #expect(PlaybackEcho.explainedShare(microphone: echo, system: system) > 0.9)
        #expect(PlaybackEcho.explainedShare(microphone: own, system: system) < 0.3)
        // Свой голос поверх эха той же громкости остаётся.
        #expect(PlaybackEcho.explainedShare(microphone: both, system: system) < PlaybackEcho.threshold)
    }

    @Test func aLineOverResidueGoesAndAnAudibleOneStays() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cyclop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mic = dir.appendingPathComponent("m.caf"), system = dir.appendingPathComponent("s.caf")
        let far = Self.noise(64_000, seed: 3), near = Self.noise(64_000, seed: 4)
        // 0–2 с: от эха остались крохи (−80 дБFS); 2–4 с: слышен свой голос.
        try Self.write(mic, rate: 16_000, channels: 1, seconds: 4) { $0 < 32_000 ? 1e-4 : near[$0] }
        try Self.write(system, rate: 16_000, channels: 1, seconds: 4) { far[$0] }
        let lines = [
            line(.other, 0, 4000, "сегодня обсудим план релиза"),
            line(.me, 200, 1800, "сегодня обходим два"),
            line(.me, 2200, 3800, "а я не согласен"),
        ]
        let kept = PlaybackEcho.dropPlayback(lines, microphone: mic, system: system)
        #expect(kept.map(\.text) == ["сегодня обсудим план релиза", "а я не согласен"])
    }

    // MARK: - Текстовые фильтры

    private func line(_ speaker: TranscriptLine.Speaker, _ start: Int, _ end: Int, _ text: String) -> TranscriptLine {
        TranscriptLine(speaker: speaker, voice: nil, startMs: start, endMs: end, text: text)
    }

    @Test func looseFilterDropsAnEchoedLineInCyrillic() {
        let lines = [
            line(.other, 0, 3000, "Давайте обсудим план на следующую неделю"),
            line(.me, 200, 3200, "давайте обсудим план на следующую неделю"),
        ]
        #expect(EchoFilter.dropEchoes(lines).map(\.speaker) == [.other])
    }

    @Test func looseFilterKeepsOwnSpeechAndShortBackchannels() {
        let lines = [
            line(.other, 0, 3000, "Давайте обсудим план на следующую неделю"),
            line(.me, 200, 1200, "Согласен, но сроки горят"),
            line(.me, 1300, 1600, "угу"),
        ]
        #expect(EchoFilter.dropEchoes(lines).count == 3)
    }

    @Test func looseFilterDropsAShortLineOnlyOnAnExactMatch() {
        let theirs = line(.other, 0, 1000, "Да конечно")
        #expect(EchoFilter.dropEchoes([theirs, line(.me, 0, 1000, "да, конечно")]).count == 1)
        #expect(EchoFilter.dropEchoes([theirs, line(.me, 0, 1000, "да нет")]).count == 2)
    }

    @Test func strictFilterNeedsEveryWordMatchedInTime() {
        let theirs = line(.other, 0, 4000, "сегодня мы поговорим про сроки релиза")
        let echo = line(.me, 100, 4100, "сегодня мы поговорим про сроки релиза")
        let mixed = line(.me, 100, 5000, "сегодня мы поговорим про сроки релиза а я не согласен")
        #expect(EchoFilter.dropResidualEchoes([theirs, echo]).map(\.speaker) == [.other])
        #expect(EchoFilter.dropResidualEchoes([theirs, mixed]).count == 2)
    }

    @Test func filtersDoNothingWithoutTheOtherSide() {
        let lines = [line(.me, 0, 1000, "просто я говорю")]
        #expect(EchoFilter.dropEchoes(lines) == lines)
        #expect(EchoFilter.dropResidualEchoes(lines) == lines)
    }
}
