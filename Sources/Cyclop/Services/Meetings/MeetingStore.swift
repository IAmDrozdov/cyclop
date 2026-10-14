import AppKit
@preconcurrency import AVFoundation
import Foundation

/// The Meetings tab's journal and the recording behind it. A meeting is a folder
/// under `folder`; the files inside it are the whole record.
@MainActor
final class MeetingStore: ObservableObject {
    /// A recording in progress.
    struct Recording: Equatable {
        let startedAt: Date
    }

    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var recording: Recording?
    @Published private(set) var microphoneDenied = false
    @Published private(set) var startFailed = false
    @Published private(set) var models: ModelsState = .missing
    /// Off by default: the two tracks take about 1 GB per hour.
    @Published var keepTracks: Bool {
        didSet { defaults.set(keepTracks, forKey: Self.keepTracksKey) }
    }

    private static let keepTracksKey = "meetingsKeepTracks"

    enum ModelsState: Equatable {
        case missing
        case downloading(Double)
        case ready
        case failed
    }

    private let folder: URL
    private let downloads: URL
    private let makeCapture: () -> MeetingCapturing
    private let now: () -> Date
    private let engine: SpeechEngine
    private let reveal: ([URL]) -> Void
    private let defaults: UserDefaults
    private var processingTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var isStarted = false
    private var compressionTried: Set<String> = []
    private var activity: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var capture: MeetingCapturing?
    private var activeFolder: URL?

    init(
        folder: URL = Support.directory("Meetings"),
        downloads: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
        makeCapture: @escaping () -> MeetingCapturing = { MeetingRecorder() },
        engine: SpeechEngine = ParakeetEngine(),
        now: @escaping () -> Date = Date.init,
        reveal: @escaping ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) },
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        keepTracks = defaults.bool(forKey: Self.keepTracksKey)
        self.folder = folder
        self.downloads = downloads
        self.makeCapture = makeCapture
        self.engine = engine
        self.now = now
        self.reveal = reveal
    }

    /// Peaks of the two tracks. Plain reads, not published: the pane polls them while drawn.
    var levels: (mic: Float, system: Float) {
        (capture?.micLevel ?? 0, capture?.systemLevel ?? 0)
    }

    // MARK: - Tab background

    func start() {
        isStarted = true
        reload()
        processPending()
    }

    /// Hiding the tab or quitting ends a recording and keeps it; a hidden tab processes nothing.
    func stop() {
        isStarted = false
        stopRecording()
        // The task stays: it ends at its next checkpoint, and until then nothing else may start on the
        // same meeting. Showing the tab again resumes the queue from the task's own tail.
        processingTask?.cancel()
    }

    // MARK: - Journal

    func reload() {
        if case .downloading = models {} else {
            models = engine.modelsReady ? .ready : (models == .failed ? .failed : .missing)
        }
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        meetings = entries.compactMap(meeting(at:)).sorted { $0.startedAt > $1.startedAt }
    }

    private func meeting(at url: URL) -> Meeting? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: url.appendingPathComponent(MeetingFile.meta)),
            let meta = try? MeetingMeta.decoder.decode(MeetingMeta.self, from: data)
        else { return nil }
        return Meeting(
            id: url.lastPathComponent,
            folder: url,
            startedAt: meta.startedAt,
            duration: meta.durationMs.map { TimeInterval($0) / 1000 } ?? Self.audioLength(in: url),
            state: state(of: url, meta: meta),
            systemSilent: meta.systemSilent ?? false,
            audioReady: !fm.fileExists(atPath: url.appendingPathComponent(MeetingFile.mic).path)
                && !fm.fileExists(atPath: url.appendingPathComponent(MeetingFile.system).path)
                || fm.fileExists(atPath: url.appendingPathComponent(MeetingFile.audio).path)
        )
    }

    private func state(of url: URL, meta: MeetingMeta) -> Meeting.State {
        if url.lastPathComponent == activeFolder?.lastPathComponent { return .recording }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent(MeetingFile.transcriptData).path) { return .ready }
        if meta.error != nil { return .failed }
        return models == .ready ? .processing : .waitingForModels
    }

    /// The length of the microphone track, for a meeting that was killed before its length was written.
    private static func audioLength(in url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url.appendingPathComponent(MeetingFile.mic)),
            file.processingFormat.sampleRate > 0
        else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: - Recording

    func startRecording() async {
        guard recording == nil else { return }
        startFailed = false
        let capture = makeCapture()
        guard await capture.requestMicrophone() == .granted else {
            microphoneDenied = true
            return
        }
        microphoneDenied = false
        guard recording == nil else { return }

        let startedAt = now()
        let url = uniqueFolder(for: startedAt)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try write(MeetingMeta(startedAt: startedAt), to: url)
            try capture.start(
                micURL: url.appendingPathComponent(MeetingFile.mic),
                systemURL: url.appendingPathComponent(MeetingFile.system)
            )
        } catch {
            // No half-meeting: a failed start leaves nothing in the journal.
            try? fm.removeItem(at: url)
            startFailed = true
            return
        }
        self.capture = capture
        activeFolder = url
        recording = Recording(startedAt: startedAt)
        holdAwake()
        reload()
    }

    func stopRecording() {
        guard let capture, let url = activeFolder, let recording else { return }
        releaseAwake()
        let starts = capture.stop()
        var meta = (try? Data(contentsOf: url.appendingPathComponent(MeetingFile.meta)))
            .flatMap { try? MeetingMeta.decoder.decode(MeetingMeta.self, from: $0) }
            ?? MeetingMeta(startedAt: recording.startedAt)
        meta.durationMs = Int(now().timeIntervalSince(recording.startedAt) * 1000)
        meta.startOffsetMs = starts.offsets
        meta.systemSilent = starts.systemHeardSound ? nil : true
        try? write(meta, to: url)
        self.capture = nil
        activeFolder = nil
        self.recording = nil
        reload()
        processPending()
    }

    // MARK: - Sleep

    /// The Mac does not idle-sleep while recording; when it is about to sleep anyway, the recording ends and is kept.
    private func holdAwake() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording a meeting"
        )
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
    }

    private func releaseAwake() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
    }

    // MARK: - Models

    /// The one place a download starts: the button.
    func downloadModels() {
        guard downloadTask == nil, models != .ready else { return }
        models = .downloading(0)
        downloadTask = Task { [engine] in
            do {
                try await engine.downloadModels { fraction in
                    Task { @MainActor in
                        if case .downloading = self.models { self.models = .downloading(fraction) }
                    }
                }
                models = engine.modelsReady ? .ready : .failed
            } catch {
                models = .failed
            }
            downloadTask = nil
            reload()
            processPending()
        }
    }

    // MARK: - Processing

    /// Takes meetings one at a time, newest first, while the tab is shown and the models are on disk.
    private func processPending() {
        guard isStarted, processingTask == nil else { return }
        let leftovers = leftoverCompressions()
        let next = models == .ready ? meetings.first(where: { $0.state == .processing }) : nil
        guard !leftovers.isEmpty || next != nil else { return }
        processingTask = Task { [engine] in
            if !leftovers.isEmpty {
                await Task.detached(priority: .utility) {
                    for (folder, offsets) in leftovers { try? MeetingPipeline.compressAudio(in: folder, offsets: offsets) }
                }.value
            }
            if let next, !Task.isCancelled { await process(next, with: MeetingPipeline(engine: engine, keepTracks: keepTracks)) }
            processingTask = nil
            reload()
            processPending()
        }
    }

    /// Ready meetings that still hold their tracks because compression failed earlier; each is tried once per launch.
    private func leftoverCompressions() -> [(URL, MeetingMeta.Offsets?)] {
        let fm = FileManager.default
        var out: [(URL, MeetingMeta.Offsets?)] = []
        for meeting in meetings where meeting.state == .ready && !compressionTried.contains(meeting.id) {
            let hasTracks = fm.fileExists(atPath: meeting.folder.appendingPathComponent(MeetingFile.mic).path)
                || fm.fileExists(atPath: meeting.folder.appendingPathComponent(MeetingFile.system).path)
            guard hasTracks, !meeting.audioReady, let meta = readMeta(at: meeting.folder) else { continue }
            compressionTried.insert(meeting.id)
            out.append((meeting.folder, meta.startOffsetMs))
        }
        return out
    }

    private func process(_ meeting: Meeting, with pipeline: MeetingPipeline) async {
        guard let meta = readMeta(at: meeting.folder) else { return }
        let title = localized("Meeting %@", meeting.id)
        do {
            try await pipeline.process(folder: meeting.folder, meta: meta, title: title, now: now())
        } catch is CancellationError {
            return
        } catch {
            var failed = meta
            failed.error = String(describing: error)
            try? write(failed, to: meeting.folder)
        }
    }

    // MARK: - Export and delete

    /// A folder in Downloads named for the meeting with its transcript and audio; Finder shows it.
    @discardableResult
    func export(_ meeting: Meeting) -> URL? {
        // A transcript with the audio still being compressed is not yet a whole meeting.
        guard meeting.state == .ready, meeting.audioReady else { return nil }
        let fm = FileManager.default
        let base = localized("Meeting %@", meeting.id)
        var target = downloads.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = downloads.appendingPathComponent("\(base) (\(n))", isDirectory: true)
            n += 1
        }
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for name in [MeetingFile.transcript, MeetingFile.audio] {
                let source = meeting.folder.appendingPathComponent(name)
                if fm.fileExists(atPath: source.path) {
                    try fm.copyItem(at: source, to: target.appendingPathComponent(name))
                }
            }
        } catch {
            try? fm.removeItem(at: target)
            return nil
        }
        reveal([target])
        return target
    }

    /// Moves the meeting to the Trash; a recording or a meeting being transcribed stays.
    @discardableResult
    func delete(_ meeting: Meeting) -> Bool {
        guard meeting.state != .recording, meeting.state != .processing, processingTask == nil || meeting.state != .ready
        else { return false }
        guard (try? FileManager.default.trashItem(at: meeting.folder, resultingItemURL: nil)) != nil else {
            return false
        }
        reload()
        return true
    }

    func retry(_ meeting: Meeting) {
        guard meeting.state == .failed, var meta = readMeta(at: meeting.folder) else { return }
        meta.error = nil
        try? write(meta, to: meeting.folder)
        reload()
        processPending()
    }

    /// The transcript of a ready meeting, as Markdown.
    func transcriptText(of meeting: Meeting) -> String? {
        guard meeting.state == .ready else { return nil }
        return try? String(
            contentsOf: meeting.folder.appendingPathComponent(MeetingFile.transcript), encoding: .utf8
        )
    }

    func copyTranscript(of meeting: Meeting) {
        guard let text = transcriptText(of: meeting) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func readMeta(at url: URL) -> MeetingMeta? {
        (try? Data(contentsOf: url.appendingPathComponent(MeetingFile.meta)))
            .flatMap { try? MeetingMeta.decoder.decode(MeetingMeta.self, from: $0) }
    }

    func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Files

    private func write(_ meta: MeetingMeta, to url: URL) throws {
        let data = try MeetingMeta.encoder.encode(meta)
        try data.write(to: url.appendingPathComponent(MeetingFile.meta), options: .atomic)
    }

    /// `2026-10-13 14-30`, with ` (2)` when that minute is taken.
    private func uniqueFolder(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let base = formatter.string(from: date)
        var candidate = folder.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(n))", isDirectory: true)
            n += 1
        }
        return candidate
    }
}
