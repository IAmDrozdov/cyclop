import AppKit
import Foundation
import Testing
@testable import Cyclop

/// Тесты на `MeetingStore`: запись, журнал и то, что остаётся на диске. Захват
/// заменён подделкой, папка — временная; настоящий звук и настоящие
/// `~/Library/Application Support/Cyclop/Meetings` здесь не участвуют.
@MainActor
struct MeetingStoreTests {

    /// Подделка захвата: пишет пару пустых файлов, как это делали бы дорожки.
    final class FakeCapture: MeetingCapturing {
        var access = MicrophoneAccess.granted
        var failsToStart = false
        var starts = TrackStarts()
        private(set) var stopped = false

        var micLevel: Float { 0.5 }
        var systemLevel: Float { 0.25 }

        func requestMicrophone() async -> MicrophoneAccess { access }

        func start(micURL: URL, systemURL: URL) throws {
            if failsToStart { throw CocoaError(.fileWriteUnknown) }
            try Data("mic".utf8).write(to: micURL)
            try Data("system".utf8).write(to: systemURL)
        }

        func stop() -> TrackStarts {
            stopped = true
            return starts
        }
    }

    /// Подделка распознавания: отдаёт заранее заданные слова и считает вызовы.
    final class FakeEngine: SpeechEngine, @unchecked Sendable {
        var modelsReady = true
        var failures = 0
        var heard: [URL] = []
        var downloads = 0
        let engineName = "fake"
        let modelName = "fake-model"

        func downloadModels(progress: @escaping @Sendable (Double) -> Void) async throws {
            downloads += 1
            modelsReady = true
        }

        func words(in audio: URL, splitAtPauses: Bool) async throws -> [TimedWord] {
            heard.append(audio)
            if failures > 0 {
                failures -= 1
                throw CocoaError(.fileReadUnknown)
            }
            let me = audio.lastPathComponent == MeetingFile.mic
            return [TimedWord(text: me ? "Привет." : "Hello.", start: 1, end: 2)]
        }

        func voiceTurns(in audio: URL) async throws -> [VoiceTurn] { [] }
    }

    private static func makeStore(
        capture: FakeCapture = FakeCapture(),
        engine: FakeEngine = FakeEngine(),
        dates: [Date] = [],
        defaults: UserDefaults = .standard
    ) throws -> (store: MeetingStore, folder: URL) {
        let downloads = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cyclop-downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cyclop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var queue = dates
        let store = MeetingStore(
            folder: folder,
            downloads: downloads,
            makeCapture: { capture },
            engine: engine,
            now: { queue.isEmpty ? Date() : queue.removeFirst() },
            reveal: { _ in },  // тест не должен открывать Finder
            defaults: defaults
        )
        return (store, folder)
    }

    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    @Test func startAndStopProduceOneMeetingWithItsLength() async throws {
        let start = Self.date("2026-10-13T14:30:00Z")
        let (store, folder) = try Self.makeStore(dates: [start, start.addingTimeInterval(125)])

        await store.startRecording()
        #expect(store.recording != nil)
        #expect(store.meetings.first?.state == .recording)

        store.stopRecording()
        #expect(store.recording == nil)
        #expect(store.meetings.count == 1)
        #expect(store.meetings[0].duration == 125)

        let files = try FileManager.default.contentsOfDirectory(atPath: store.meetings[0].folder.path)
        #expect(Set(files) == [MeetingFile.meta, MeetingFile.mic, MeetingFile.system])
        _ = folder
    }

    @Test func startOffsetsAreSavedWithTheMeeting() async throws {
        let capture = FakeCapture()
        let origin = Self.date("2026-10-13T14:30:00Z")
        capture.starts = TrackStarts(mic: origin.addingTimeInterval(0.4), system: origin)
        let (store, _) = try Self.makeStore(capture: capture)

        await store.startRecording()
        store.stopRecording()

        let data = try Data(contentsOf: store.meetings[0].folder.appendingPathComponent(MeetingFile.meta))
        let meta = try MeetingMeta.decoder.decode(MeetingMeta.self, from: data)
        #expect(meta.startOffsetMs == .init(mic: 400, system: 0))
    }

    @Test func journalIsNewestFirst() async throws {
        let first = Self.date("2026-10-13T09:00:00Z")
        let second = Self.date("2026-10-13T15:00:00Z")
        let (store, _) = try Self.makeStore(dates: [first, first.addingTimeInterval(60), second, second.addingTimeInterval(60)])

        await store.startRecording()
        store.stopRecording()
        await store.startRecording()
        store.stopRecording()

        #expect(store.meetings.count == 2)
        #expect(store.meetings[0].startedAt > store.meetings[1].startedAt)
    }

    @Test func failedStartLeavesNoHalfMeeting() async throws {
        let capture = FakeCapture()
        capture.failsToStart = true
        let (store, folder) = try Self.makeStore(capture: capture)

        await store.startRecording()

        #expect(store.recording == nil)
        #expect(store.startFailed)
        #expect(store.meetings.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func refusedMicrophoneStartsNothingAndSaysSo() async throws {
        let capture = FakeCapture()
        capture.access = .denied
        let (store, folder) = try Self.makeStore(capture: capture)

        await store.startRecording()

        #expect(store.recording == nil)
        #expect(store.microphoneDenied)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func hidingTheTabEndsARecordingAndKeepsIt() async throws {
        let capture = FakeCapture()
        let (store, _) = try Self.makeStore(capture: capture)
        store.start()

        await store.startRecording()
        store.stop()

        #expect(capture.stopped)
        #expect(store.recording == nil)
        #expect(store.meetings.count == 1)
    }

    @Test func meetingKilledBeforeItsLengthWasWrittenStillListsWithoutALength() async throws {
        let (store, folder) = try Self.makeStore()
        let killed = folder.appendingPathComponent("2026-10-12 10-00", isDirectory: true)
        try FileManager.default.createDirectory(at: killed, withIntermediateDirectories: true)
        let meta = MeetingMeta(startedAt: Self.date("2026-10-12T10:00:00Z"))
        try MeetingMeta.encoder.encode(meta).write(to: killed.appendingPathComponent(MeetingFile.meta))

        store.reload()

        #expect(store.meetings.count == 1)
        #expect(store.meetings[0].duration == nil)
    }

    // MARK: - Расшифровка

    /// Ждёт, пока очередь расшифровки опустеет.
    private static func settle(_ store: MeetingStore) async {
        for _ in 0..<200 {
            if !store.meetings.contains(where: { $0.state == .processing }) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func meetingWaitsForModelsAndIsTranscribedAfterTheDownload() async throws {
        let engine = FakeEngine()
        engine.modelsReady = false
        let (store, _) = try Self.makeStore(engine: engine)
        store.start()

        await store.startRecording()
        store.stopRecording()
        #expect(store.meetings[0].state == .waitingForModels)
        #expect(engine.heard.isEmpty)

        store.downloadModels()
        for _ in 0..<200 where store.meetings.first?.state != .ready {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.downloads == 1)
        #expect(store.meetings[0].state == .ready)
    }

    @Test func stoppedMeetingGetsMarkdownThenJsonWithBothSpeakers() async throws {
        let (store, _) = try Self.makeStore()
        store.start()

        await store.startRecording()
        store.stopRecording()
        await Self.settle(store)

        let meeting = store.meetings[0]
        #expect(meeting.state == .ready)
        let text = try #require(store.transcriptText(of: meeting))
        #expect(text.contains("Привет."))
        #expect(text.contains("Hello."))
        #expect(FileManager.default.fileExists(
            atPath: meeting.folder.appendingPathComponent(MeetingFile.transcriptData).path))
    }

    @Test func unfinishedMeetingsAreFoundAtStartAndProcessedOneByOne() async throws {
        let engine = FakeEngine()
        let (store, folder) = try Self.makeStore(engine: engine)
        for name in ["2026-10-10 10-00", "2026-10-11 10-00"] {
            let dir = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent(MeetingFile.mic))
            try MeetingMeta.encoder.encode(MeetingMeta(startedAt: Self.date("2026-10-10T10:00:00Z")))
                .write(to: dir.appendingPathComponent(MeetingFile.meta))
        }

        store.start()
        await Self.settle(store)
        for _ in 0..<200 where store.meetings.contains(where: { $0.state != .ready }) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.meetings.count == 2)
        #expect(store.meetings.allSatisfy { $0.state == .ready })
        #expect(engine.heard.count == 2)
    }

    @Test func failureKeepsAudioAndRetryProcessesAgain() async throws {
        let engine = FakeEngine()
        engine.failures = 1
        let (store, _) = try Self.makeStore(engine: engine)
        store.start()

        await store.startRecording()
        store.stopRecording()
        for _ in 0..<200 where store.meetings.first?.state != .failed {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let failed = store.meetings[0]
        #expect(failed.state == .failed)
        #expect(FileManager.default.fileExists(atPath: failed.folder.appendingPathComponent(MeetingFile.mic).path))

        store.retry(failed)
        for _ in 0..<200 where store.meetings.first?.state != .ready {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.meetings[0].state == .ready)
    }

    @Test func hiddenTabProcessesNothing() async throws {
        let engine = FakeEngine()
        let (store, folder) = try Self.makeStore(engine: engine)
        let dir = folder.appendingPathComponent("2026-10-10 10-00", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent(MeetingFile.mic))
        try MeetingMeta.encoder.encode(MeetingMeta(startedAt: Self.date("2026-10-10T10:00:00Z")))
            .write(to: dir.appendingPathComponent(MeetingFile.meta))

        store.reload()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(engine.heard.isEmpty)
    }

    // MARK: - Выгрузка и удаление

    /// Готовая встреча с обоими файлами; сжатие в тестах не участвует, файлы кладутся руками.
    private static func readyMeeting(_ store: MeetingStore) async throws -> Meeting {
        store.start()
        await store.startRecording()
        store.stopRecording()
        for _ in 0..<200 where store.meetings.first?.state != .ready {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let meeting = try #require(store.meetings.first)
        try Data("audio".utf8).write(to: meeting.folder.appendingPathComponent(MeetingFile.audio))
        store.reload()
        return try #require(store.meetings.first)
    }

    @Test func exportCopiesExactlyTheTranscriptAndTheAudio() async throws {
        let (store, _) = try Self.makeStore()
        let meeting = try await Self.readyMeeting(store)

        let target = try #require(store.export(meeting))

        let names = try FileManager.default.contentsOfDirectory(atPath: target.path)
        #expect(Set(names) == [MeetingFile.transcript, MeetingFile.audio])
        #expect(target.deletingLastPathComponent().lastPathComponent.hasPrefix("cyclop-downloads-"))
        #expect(store.meetings.count == 1)
    }

    @Test func aSecondExportGetsANumberedFolder() async throws {
        let (store, _) = try Self.makeStore()
        let meeting = try await Self.readyMeeting(store)

        let first = try #require(store.export(meeting))
        let second = try #require(store.export(meeting))

        #expect(first != second)
        #expect(second.lastPathComponent.hasSuffix("(2)"))
        #expect(FileManager.default.fileExists(atPath: first.path))
    }

    @Test func deleteMovesTheMeetingOutOfTheJournal() async throws {
        let (store, _) = try Self.makeStore()
        let meeting = try await Self.readyMeeting(store)

        #expect(store.delete(meeting))
        #expect(store.meetings.isEmpty)
    }

    @Test func aRecordingInProgressCannotBeDeletedOrExported() async throws {
        let (store, _) = try Self.makeStore()
        await store.startRecording()
        let live = try #require(store.meetings.first)

        #expect(live.state == .recording)
        #expect(!store.delete(live))
        #expect(store.export(live) == nil)
        #expect(store.meetings.count == 1)
        store.stopRecording()
    }

    // MARK: - Сон, скрытая вкладка, тишина системы

    @Test func aSilentSystemTrackIsMarkedInTheJournal() async throws {
        let capture = FakeCapture()
        capture.starts.systemHeardSound = false
        let (store, _) = try Self.makeStore(capture: capture)

        await store.startRecording()
        store.stopRecording()

        #expect(store.meetings[0].systemSilent)
    }

    @Test func aSystemTrackWithSoundIsNotMarked() async throws {
        let (store, _) = try Self.makeStore()
        await store.startRecording()
        store.stopRecording()
        #expect(!store.meetings[0].systemSilent)
    }

    @Test func theMacGoingToSleepEndsTheRecordingAndKeepsIt() async throws {
        let capture = FakeCapture()
        let (store, _) = try Self.makeStore(capture: capture)

        await store.startRecording()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(capture.stopped)
        #expect(store.recording == nil)
        #expect(store.meetings.count == 1)
    }

    @Test func processingResumesWhenTheTabIsShownAgain() async throws {
        let engine = FakeEngine()
        let (store, folder) = try Self.makeStore(engine: engine)
        let dir = folder.appendingPathComponent("2026-10-10 10-00", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent(MeetingFile.mic))
        try MeetingMeta.encoder.encode(MeetingMeta(startedAt: Self.date("2026-10-10T10:00:00Z")))
            .write(to: dir.appendingPathComponent(MeetingFile.meta))

        // Скрыли и показали вкладку, пока задача ещё идёт: встреча обрабатывается один раз и не падает.
        store.start()
        store.stop()
        store.start()
        for _ in 0..<300 where store.meetings.first?.state != .ready {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.meetings[0].state == .ready)
        #expect(engine.heard.count <= 2)
    }

    @Test func leftoverCompressionAtStartKeepsTheTracksWhenAsked() async throws {
        let suite = "cyclop-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, folder) = try Self.makeStore(defaults: defaults)
        store.keepTracks = true

        // Готовая встреча из прошлого запуска: расшифровка есть, дорожки настоящие, audio.m4a нет.
        let dir = folder.appendingPathComponent("2026-10-10 10-00", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try TrackCompressorTests.tone(
            dir.appendingPathComponent(MeetingFile.mic), seconds: 1, rate: 48_000, channels: 1, amplitude: 0.5)
        try TrackCompressorTests.tone(
            dir.appendingPathComponent(MeetingFile.system), seconds: 1, rate: 48_000, channels: 2, amplitude: 0.5)
        try MeetingMeta.encoder.encode(MeetingMeta(startedAt: Self.date("2026-10-10T10:00:00Z")))
            .write(to: dir.appendingPathComponent(MeetingFile.meta))
        try Data("{}".utf8).write(to: dir.appendingPathComponent(MeetingFile.transcriptData))

        store.start()
        for _ in 0..<300 where store.meetings.first?.audioReady != true {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.meetings.first?.audioReady == true)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(MeetingFile.audio).path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(MeetingFile.mic).path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(MeetingFile.system).path))
    }

    @Test func exportWaitsForTheAudioToBeCompressed() async throws {
        let (store, _) = try Self.makeStore()
        store.start()
        await store.startRecording()
        store.stopRecording()
        for _ in 0..<200 where store.meetings.first?.state != .ready {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // Дорожки в тесте не настоящие, сжатие не удалось: звука ещё нет.
        let meeting = try #require(store.meetings.first)
        #expect(!meeting.audioReady)
        #expect(store.export(meeting) == nil)
    }
}
