#if CYCLOP_DEMO
import AVFoundation
import AppKit
import Combine

/// The demo build (`Scripts/bundle.sh demo`): invented data in a throwaway folder, for README pictures. See docs/architecture.md, "The demo build".
enum Demo {
    /// `CYCLOP_DEMO_DIR`; the build refuses to start without it rather than fall back to the real folders.
    static let folder: URL = {
        let env = ProcessInfo.processInfo.environment
        // Its own bundle id is what keeps the demo off the real preferences domain.
        guard Bundle.main.bundleIdentifier == "com.cyclop.app.demo" else {
            fatalError("Cyclop Demo: runs only as com.cyclop.app.demo (Scripts/bundle.sh demo)")
        }
        guard let path = env["CYCLOP_DEMO_DIR"], path.hasPrefix("/") else {
            fatalError("Cyclop Demo: CYCLOP_DEMO_DIR must name an absolute folder")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        // The shooter marks the folder it made, so no existing folder is taken for a demo one.
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".cyclop-demo").path) else {
            fatalError("Cyclop Demo: CYCLOP_DEMO_DIR has no .cyclop-demo mark")
        }
        // Claude's settings file is the one thing the hook edit writes outside the support folder.
        guard let settings = env["CYCLOP_CLAUDE_SETTINGS"],
            URL(fileURLWithPath: settings).resolvingSymlinksInPath().path.hasPrefix(url.path + "/")
        else { fatalError("Cyclop Demo: CYCLOP_CLAUDE_SETTINGS must point inside CYCLOP_DEMO_DIR") }
        return url
    }()

    static var support: URL { folder.appendingPathComponent("support", isDirectory: true) }
    static var sessions: URL { folder.appendingPathComponent("sessions", isDirectory: true) }
    static var files: URL { folder.appendingPathComponent("files", isDirectory: true) }
    static var pictures: URL { folder.appendingPathComponent("pictures", isDirectory: true) }
    private static var seededMark: URL { folder.appendingPathComponent("seeded") }
    private static var readyFile: URL { folder.appendingPathComponent("ready.json") }

    /// `CYCLOP_DEMO_TAB`: the tab the panel opens on.
    static let tab: NotchViewModel.Tab = {
        let name = ProcessInfo.processInfo.environment["CYCLOP_DEMO_TAB"] ?? "claude"
        guard let tab = NotchViewModel.Tab(rawValue: name) else { fatalError("Cyclop Demo: unknown tab \(name)") }
        return tab
    }()

    /// Seeding writes meetings at their own times; afterwards the clock is the real one.
    @MainActor static var clock: Date?
    @MainActor static func now() -> Date { clock ?? Date() }

    // MARK: - Stores

    @MainActor static func makeClaude() -> ClaudeStore {
        ClaudeStore(
            folder: sessions,
            isAlive: { _, _ in true },
            defaultPlanChoice: { PlanChoice(ConfigStore.shared.planApproval) }
        )
    }

    @MainActor static func makeMeetings() -> MeetingStore {
        MeetingStore(
            folder: support.appendingPathComponent("Meetings", isDirectory: true),
            downloads: folder.appendingPathComponent("Downloads", isDirectory: true),
            makeCapture: { Capture() },
            engine: Speech(scripts: meetingScripts),
            now: { now() },
            reveal: { _ in }
        )
    }

    @MainActor static func makeCaffeine() -> CaffeineStore {
        CaffeineStore(
            port: Power(),
            minutes: ConfigStore.shared.caffeineMinutes,
            lidClosedMode: ConfigStore.shared.caffeineLidClosed,
            onMinutesChange: { ConfigStore.shared.caffeineMinutes = $0 },
            onLidClosedModeChange: { ConfigStore.shared.caffeineLidClosed = $0 }
        )
    }

    // MARK: - Before the model

    /// Files the stores read at creation, written through the stores' own writers, once per demo folder.
    @MainActor static func seedFiles() {
        let fm = FileManager.default
        for url in [support, sessions, files, pictures] {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        writeSessions()
        guard !fm.fileExists(atPath: seededMark.path) else { return }

        let config = ConfigStore.shared
        config.hiddenTabs = []
        config.privacy = []
        config.caffeineMinutes = 90
        config.flush()

        let snippets = SnippetStore()
        for (label, text) in snippetSeed.reversed() { snippets.add(label: label, text: text) }

        let teleprompter = TeleprompterStore()
        teleprompter.script = teleprompterSeed
        teleprompter.flush()

        ShelfStore().add(shelfSeed())
        UserDefaults.standard.set("eur", forKey: "currency.target")
        UserDefaults.standard.set("usd", forKey: "currency.source")
    }

    // MARK: - After the model

    /// Seeds what lives in memory or needs the running stores, opens the panel and writes `ready.json`.
    @MainActor static func present(vm: NotchViewModel, panel: @escaping @MainActor () -> NotchScreenPanel?) {
        for (offset, text) in clipboardSeed.enumerated().reversed() {
            vm.clipboard.demoRecord(.text(text), date: Date().addingTimeInterval(-Double(offset + 1) * 260))
        }
        vm.clipboard.demoRecord(.file(files.appendingPathComponent("Q4 roadmap.pdf")), date: Date().addingTimeInterval(-90))
        vm.translator.input = "Созвон переносится на четверг, 15:00. Пришлю ссылку утром."
        vm.currencies.setSourceText("250")
        if vm.claude.connection != .connected { vm.claude.connect() }

        Task { @MainActor in
            if !FileManager.default.fileExists(atPath: seededMark.path) {
                await recordMeetings(into: vm.meetings)
                try? Data().write(to: seededMark)
            }
            vm.tab = tab
            panel()?.openForRequest()
            await settle(vm: vm)
            writeReady(vm: vm, panel: panel())
        }
    }

    /// Waits for what fills in after opening: thumbnails, rates, transcripts.
    @MainActor private static func settle(vm: NotchViewModel) async {
        for _ in 0..<120 {
            try? await Task.sleep(for: .milliseconds(250))
            let meetingsBusy = vm.meetings.meetings.contains { $0.state == .processing || $0.state == .recording }
            if !meetingsBusy, vm.currencies.rateDate != nil { break }
        }
        try? await Task.sleep(for: .milliseconds(900))
    }

    /// The window to capture and the body's rect in it, in points from the window's top left.
    @MainActor private static func writeReady(vm: NotchViewModel, panel: NotchScreenPanel?) {
        guard let panel, let window = panel.demoWindow else { return }
        let body = panel.state.openBodySize
        let width = body.width + 2 * Theme.openTopRadius
        let info: [String: Any] = [
            "tab": vm.tab.rawValue,
            "window": window.windowNumber,
            "scale": window.backingScaleFactor,
            "x": (window.frame.width - width) / 2,
            "y": 0,
            "width": width,
            "height": body.height,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) {
            try? data.write(to: readyFile, options: .atomic)
        }
        // The request picture waits for the card itself.
        requestWatch = vm.claude.$requests.sink { requests in
            guard !requests.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                try? Data("\(requests.count)".utf8).write(to: folder.appendingPathComponent("request.ready"))
            }
        }
    }

    @MainActor private static var requestWatch: AnyCancellable?

    // MARK: - Claude sessions

    /// Sessions as Claude Code writes them to `~/.claude/sessions/<pid>.json`, times fresh on every launch.
    @MainActor private static func writeSessions() {
        let now = Date().timeIntervalSince1970 * 1000
        for session in sessionSeed {
            var object: [String: Any] = [
                "pid": session.pid,
                "sessionId": session.id,
                "cwd": session.cwd,
                "name": session.name,
                "entrypoint": session.entrypoint,
                "kind": "interactive",
                "status": session.status,
                "startedAt": now - session.minutesAgo * 60_000 - 1_800_000,
                "statusUpdatedAt": now - session.minutesAgo * 60_000,
            ]
            if let waiting = session.waitingFor { object["waitingFor"] = waiting }
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                try? data.write(to: sessions.appendingPathComponent("\(session.pid).json"), options: .atomic)
            }
        }
    }

    struct SessionSeed {
        let pid: Int
        let id: String
        let name: String
        let cwd: String
        let entrypoint: String
        let status: String
        let waitingFor: String?
        let minutesAgo: Double
    }

    /// The session the shooter's request comes from (`shoot.sh`).
    static let requestSessionID = "5d0c6a52-8f1e-4b7a-9c3d-2e61f0a4b917"

    static let sessionSeed: [SessionSeed] = [
        SessionSeed(
            pid: 48213, id: requestSessionID, name: "Fix flaky checkout test", cwd: "/Users/demo/code/storefront",
            entrypoint: "cli", status: "waiting", waitingFor: "permission prompt", minutesAgo: 1),
        SessionSeed(
            pid: 48377, id: "a1f4e9c2-3b6d-4e8f-9a0b-7c5d2e1f3a64", name: "Retry failed webhooks",
            cwd: "/Users/demo/code/billing", entrypoint: "claude-desktop", status: "busy", waitingFor: nil,
            minutesAgo: 4),
        SessionSeed(
            pid: 48502, id: "c7b2d8e1-6f4a-4c3b-8d9e-1a2b3c4d5e6f", name: "Search index rebuild",
            cwd: "/Users/demo/code/search", entrypoint: "claude-vscode", status: "busy", waitingFor: nil,
            minutesAgo: 12),
        SessionSeed(
            pid: 47990, id: "e3d4c5b6-a7f8-4e9d-8c1b-2a3f4e5d6c7b", name: "API reference cleanup",
            cwd: "/Users/demo/code/docs", entrypoint: "cli", status: "idle", waitingFor: nil, minutesAgo: 38),
    ]

    // MARK: - Meetings

    struct MeetingScript: Sendable {
        /// Who speaks when: `nil` voice is the owner, 0 and 1 are the two remote voices.
        let lines: [(voice: Int?, at: Double, text: String)]
        let start: DateComponents
        let minutes: Int
        let systemSilent: Bool
    }

    static let meetingSeed: [MeetingScript] = [
        MeetingScript(
            lines: [
                (nil, 1, "Morning. Shall we start with the release?"),
                (0, 4, "Sure. The build is green, two fixes are still in review."),
                (1, 9, "I can take the checkout one after lunch."),
                (nil, 13, "Great. Then we ship on Thursday."),
            ],
            start: DateComponents(year: 2026, month: 10, day: 14, hour: 10, minute: 0), minutes: 32,
            systemSilent: false),
        MeetingScript(
            lines: [
                (nil, 1, "Thanks for joining. Let us go over the quarter."),
                (0, 5, "Revenue is up, churn is flat."),
                (nil, 9, "Good. What is blocking the onboarding work?"),
                (0, 13, "Mostly design review. It lands next week."),
            ],
            start: DateComponents(year: 2026, month: 10, day: 13, hour: 15, minute: 30), minutes: 58,
            systemSilent: false),
        MeetingScript(
            lines: [
                (nil, 1, "Notes for the hiring loop: strong system design, ask about testing."),
                (nil, 6, "Follow up with the recruiter on Friday."),
            ],
            start: DateComponents(year: 2026, month: 10, day: 12, hour: 17, minute: 5), minutes: 6,
            systemSilent: true),
        MeetingScript(
            lines: [
                (nil, 1, "Can you hear me? Great."),
                (0, 3, "Yes. I sent the contract this morning."),
                (nil, 7, "Got it, I will sign it today."),
            ],
            start: DateComponents(year: 2026, month: 10, day: 9, hour: 11, minute: 15), minutes: 21,
            systemSilent: false),
    ]

    static func startDate(of script: MeetingScript) -> Date {
        Calendar.current.date(from: script.start) ?? Date(timeIntervalSince1970: 0)
    }

    /// Keyed by the folder `MeetingStore` names after the start minute.
    static var meetingScripts: [String: MeetingScript] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return Dictionary(uniqueKeysWithValues: meetingSeed.map { (formatter.string(from: startDate(of: $0)), $0) })
    }

    /// Each meeting goes through Start and Stop Recording on the demo clock, then the store's own processing.
    @MainActor private static func recordMeetings(into store: MeetingStore) async {
        for script in meetingSeed.sorted(by: { startDate(of: $0) < startDate(of: $1) }) {
            let start = startDate(of: script)
            clock = start
            Capture.systemSilent = script.systemSilent
            await store.startRecording()
            clock = start.addingTimeInterval(TimeInterval(script.minutes * 60))
            store.stopRecording()
        }
        clock = nil
        for _ in 0..<240 {
            try? await Task.sleep(for: .milliseconds(250))
            if !store.meetings.contains(where: { $0.state == .processing }) { break }
        }
    }

    /// Writes two short tracks the way the recorders do (16-bit PCM CAF); nothing is heard.
    final class Capture: MeetingCapturing {
        @MainActor static var systemSilent = false
        var micLevel: Float { 0 }
        var systemLevel: Float { 0 }
        private var silent = false

        func requestMicrophone() async -> MicrophoneAccess { .granted }

        func start(micURL: URL, systemURL: URL) throws {
            silent = MainActor.assumeIsolated { Self.systemSilent }
            try Self.writeTrack(to: micURL, seconds: 20)
            try Self.writeTrack(to: systemURL, seconds: silent ? 0 : 20)
        }

        func stop() -> TrackStarts {
            let now = MainActor.assumeIsolated { Demo.now() }
            return TrackStarts(mic: now, system: now, systemHeardSound: !silent)
        }

        private static func writeTrack(to url: URL, seconds: Int) throws {
            let rate = 16_000.0
            let file = try AVAudioFile(
                forWriting: url, settings: AudioLevel.pcmSettings(sampleRate: rate, channels: 1),
                commonFormat: .pcmFormatFloat32, interleaved: false)
            guard seconds > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate) * UInt32(seconds))
            else { return }
            buffer.frameLength = buffer.frameCapacity
            try file.write(from: buffer)
        }
    }

    /// Hands back the script's words: the microphone is read whole, the system track split at pauses.
    struct Speech: SpeechEngine {
        let scripts: [String: MeetingScript]
        let engineName = "parakeet"
        let modelName = "parakeet-tdt-0.6b-v3-coreml"
        var modelsReady: Bool { true }

        func downloadModels(progress: @escaping @Sendable (Double) -> Void) async throws {}

        func words(in audio: URL, splitAtPauses: Bool) async throws -> [TimedWord] {
            guard let script = scripts[audio.deletingLastPathComponent().lastPathComponent] else { return [] }
            return script.lines.filter { ($0.voice == nil) != splitAtPauses }.flatMap(Self.words)
        }

        func voiceTurns(in audio: URL) async throws -> [VoiceTurn] {
            guard let script = scripts[audio.deletingLastPathComponent().lastPathComponent] else { return [] }
            return script.lines.compactMap { line in
                guard let voice = line.voice else { return nil }
                let words = Self.words(line)
                return VoiceTurn(voice: "S\(voice)", start: line.at, end: words.last?.end ?? line.at)
            }
        }

        private static func words(_ line: (voice: Int?, at: Double, text: String)) -> [TimedWord] {
            line.text.split(separator: " ").enumerated().map { index, word in
                let start = line.at + Double(index) * 0.3
                return TimedWord(text: String(word), start: start, end: start + 0.25)
            }
        }
    }

    // MARK: - Caffeine

    /// A laptop's port that touches nothing: no assertion, no lid bit.
    @MainActor final class Power: PowerPort {
        var hasLid: Bool { true }
        var lidClosed: Bool { false }
        var onLidChange: (() -> Void)?
        var onMayHaveChanged: (() -> Void)?
        func holdIdleSleep() {}
        func releaseIdleSleep() {}
        func setLidSleepDisabled(_ disabled: Bool) {}
    }

    // MARK: - Currency

    /// The two endpoints the store asks for, answered from here instead of the network.
    static func currencyResponse(_ endpoint: String) throws -> Data {
        if endpoint == "currencies.min.json" {
            return try JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: currencyNames))
        }
        let rates: [String: Double] = [
            "usd": 1, "eur": 0.9187, "rub": 81.42, "gbp": 0.7643, "cny": 7.1214, "jpy": 149.83,
            "chf": 0.8061, "try": 34.27, "kzt": 487.6, "uah": 41.32, "byn": 3.27, "pln": 3.9518,
            "aed": 3.6725, "btc": 0.00001587, "eth": 0.000412, "usdt": 1.0003, "cad": 1.3791, "sek": 10.42,
        ]
        let base = endpoint.replacingOccurrences(of: "currencies/", with: "")
            .replacingOccurrences(of: ".min.json", with: "")
        guard let unit = rates[base] else { throw URLError(.fileDoesNotExist) }
        let table = rates.mapValues { $0 / unit }
        return try JSONSerialization.data(withJSONObject: ["date": "2026-10-14", base: table])
    }

    private static let currencyNames: [(String, String)] = [
        ("usd", "US Dollar"), ("eur", "Euro"), ("rub", "Russian Ruble"), ("gbp", "British Pound"),
        ("cny", "Chinese Yuan Renminbi"), ("jpy", "Japanese Yen"), ("chf", "Swiss Franc"),
        ("try", "Turkish Lira"), ("kzt", "Kazakhstani Tenge"), ("uah", "Ukrainian Hryvnia"),
        ("byn", "Belarusian Ruble"), ("pln", "Polish Zloty"), ("aed", "Emirati Dirham"), ("btc", "Bitcoin"),
        ("eth", "Ethereum"), ("usdt", "Tether"), ("cad", "Canadian Dollar"), ("sek", "Swedish Krona"),
    ]

    // MARK: - Translate

    /// What the on-device model gives for the demo sentence; any other text comes back as it went in.
    static func translation(of text: String) -> String {
        text == "Созвон переносится на четверг, 15:00. Пришлю ссылку утром."
            ? "The call is moved to Thursday at 3 pm. I will send the link in the morning." : text
    }

    // MARK: - Seeds

    static let snippetSeed: [(String, String)] = [
        ("Signature", "Best,\nAlex Morgan\nProduct Engineer, Northwind"),
        ("Meeting link", "https://meet.example.com/northwind-weekly"),
        ("Office address", "Northwind Ltd., 221 Harbour Street, Suite 4, Lisbon"),
        ("", "Thanks! I will take a look today and get back to you."),
    ]

    static let clipboardSeed: [String] = [
        "https://github.com/akalikbergenov/cyclop",
        "Can we move the sync to 3 pm?",
        "git rebase -i origin/main",
        "#4F46E5",
        "Order A-20431 has shipped and should arrive on Friday.",
        "SELECT id, email FROM users WHERE created_at > now() - interval '7 days';",
    ]

    static let teleprompterSeed = """
        Hi everyone, and thanks for joining the product update.

        This quarter we shipped three things you asked for most: faster search, \
        offline mode, and a cleaner onboarding.

        Search is now twice as fast on large workspaces. Offline mode keeps your \
        last thirty days on the device, and syncs the moment you are back online.

        Next, a quick demo, and then your questions.
        """

    /// Five files of the kinds people keep on a shelf, drawn here so no real file is shown.
    @MainActor private static func shelfSeed() -> [URL] {
        let names = ["Q4 roadmap.pdf", "Onboarding flow v3.png", "release-notes.md", "Team offsite.png", "invoice-0142.pdf"]
        writeImage(to: files.appendingPathComponent("Onboarding flow v3.png"), colors: [.systemIndigo, .systemPurple], cards: true)
        writeImage(to: files.appendingPathComponent("Team offsite.png"), colors: [.systemTeal, .systemBlue], cards: false)
        writePDF(to: files.appendingPathComponent("Q4 roadmap.pdf"), title: "Q4 Roadmap",
                 lines: ["Faster search", "Offline mode", "New onboarding", "Billing retries"])
        writePDF(to: files.appendingPathComponent("invoice-0142.pdf"), title: "Invoice 0142",
                 lines: ["Design services, October", "Total: 2,400.00 EUR"])
        try? Data("# Release notes\n\n- Faster search\n- Offline mode\n- Bug fixes\n".utf8)
            .write(to: files.appendingPathComponent("release-notes.md"))
        // `add` puts each new file first, so the last one added leads the shelf.
        return names.reversed().map { files.appendingPathComponent($0) }
    }

    @MainActor private static func writeImage(to url: URL, colors: [NSColor], cards: Bool) {
        let size = NSSize(width: 640, height: 400)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: colors)?.draw(in: rect, angle: 35)
            NSColor.white.withAlphaComponent(cards ? 0.85 : 0.25).setFill()
            if cards {
                for i in 0..<3 {
                    NSBezierPath(roundedRect: NSRect(x: 40 + CGFloat(i) * 195, y: 60, width: 170, height: 280),
                                 xRadius: 18, yRadius: 18).fill()
                }
            } else {
                NSBezierPath(ovalIn: NSRect(x: 420, y: 230, width: 110, height: 110)).fill()
                NSColor.black.withAlphaComponent(0.25).setFill()
                NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 120)).fill()
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    @MainActor private static func writePDF(to url: URL, title: String, lines: [String]) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (title as NSString).draw(at: NSPoint(x: 60, y: 690), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 34)])
        for (index, line) in lines.enumerated() {
            ("•  " + line as NSString).draw(
                at: NSPoint(x: 60, y: 620 - CGFloat(index) * 40),
                withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.darkGray])
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
    }
}

#endif
