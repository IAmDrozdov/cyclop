import Foundation
import Testing
@testable import Cyclop

/// Тесты на `ClaudeStore`: список сессий из файлов Claude Code. Папка —
/// временная, «жив ли процесс» и время подменены; настоящие `~/.claude/sessions`
/// здесь не участвуют.
@MainActor
struct ClaudeStoreTests {

    private static let t0 = Date(timeIntervalSince1970: 1_791_900_000)

    /// Подделка системы: запоминает, что её попросили открыть, вывести вперёд и показать вкладкой.
    @MainActor
    final class FakeOpener: ClaudeOpening {
        var hosts: [Int: ClaudeHostApp] = [:]
        private(set) var opened: [URL] = []
        private(set) var broughtForward: [ClaudeHostApp] = []
        private(set) var focused: [Int] = []
        /// Находит ли терминал вкладку процесса (в жизни: разрешена ли автоматизация).
        var tabFound = false
        /// Что напечатали в терминалах: команда и процесс, рядом с которым открыли вкладку.
        private(set) var typed: [(command: String, pid: Int)] = []
        /// Чем кончился скрипт терминала (в жизни: разрешена ли автоматизация).
        var typingResult = ClaudeTerminalResult.done
        private(set) var copied: [String] = []

        func hostApp(ofProcess pid: Int) -> ClaudeHostApp? { hosts[pid] }
        func open(_ url: URL) { opened.append(url) }
        func bringForward(_ app: ClaudeHostApp) { broughtForward.append(app) }
        func focusTab(ofProcess pid: Int, in app: ClaudeHostApp) -> Bool {
            focused.append(pid)
            return tabFound
        }
        func runInTerminal(_ command: String, besideProcess pid: Int, in app: ClaudeHostApp) async -> ClaudeTerminalResult {
            typed.append((command, pid))
            return typingResult
        }
        func copyToPasteboard(_ text: String) { copied.append(text) }
    }

    /// Подделка `claude -p`: запоминает запуски и отвечает по очереди; без очереди — успехом.
    final class FakeRunner: ClaudeRunning, @unchecked Sendable {
        struct Call: Equatable {
            var executable: URL
            var arguments: [String]
            var folder: URL
        }

        private let lock = NSLock()
        private var made: [Call] = []
        private var queue: [ClaudeRun] = []
        private var lastEnvironment: [String: String] = [:]

        var calls: [Call] { lock.withLock { made } }
        var environment: [String: String] { lock.withLock { lastEnvironment } }
        /// Ответы на следующие запуски по порядку.
        func answer(_ runs: ClaudeRun...) { lock.withLock { queue = runs } }

        func run(
            executable: URL, arguments: [String], folder: URL, environment: [String: String], timeout: TimeInterval
        ) async -> ClaudeRun {
            lock.withLock {
                made.append(Call(executable: executable, arguments: arguments, folder: folder))
                lastEnvironment = environment
                return queue.isEmpty ? ClaudeRun(status: 0, standardError: "") : queue.removeFirst()
            }
        }
    }

    /// Подделка сокета: запоминает, запущен ли он, и приносит запросы, как принёс бы слушатель.
    @MainActor
    final class FakeListener: ClaudeListening {
        private(set) var starts = 0
        private(set) var stops = 0
        private(set) var isListening = false
        var failure: ClaudeListener.StartError?
        private var handler: (@MainActor @Sendable (Data, any ClaudeReplying) -> Void)?

        func start(onRequest: @escaping @MainActor @Sendable (Data, any ClaudeReplying) -> Void) throws {
            if let failure { throw failure }
            starts += 1
            isListening = true
            handler = onRequest
        }

        func stop() {
            stops += 1
            isListening = false
        }

        /// Запрос приходит с новым соединением.
        @discardableResult
        func arrive(_ body: String) -> FakeRelay {
            let relay = FakeRelay()
            handler?(Data(body.utf8), relay)
            return relay
        }
    }

    /// Подделка ретранслятора: что ему ответили, закрыт ли он, и «хук убит».
    final class FakeRelay: ClaudeReplying, @unchecked Sendable {
        private(set) var replies: [String] = []
        private(set) var isClosed = false
        private var hangup: (@Sendable () -> Void)?

        func reply(_ data: Data) {
            replies.append(String(decoding: data, as: UTF8.self))
            isClosed = true
        }

        func close() { isClosed = true }
        func onHangup(_ handler: @escaping @Sendable () -> Void) { hangup = handler }
        func hangUp() { hangup?() }
    }

    /// Папка сессий с подменёнными часами и списком «живых» процессов.
    @MainActor
    final class Rig {
        let folder: URL
        var alive: Set<Int> = []
        var moment = ClaudeStoreTests.t0
        let opener = FakeOpener()
        let listener = FakeListener()
        let runner = FakeRunner()
        /// Что «знает» стор о планах: настройки по умолчанию, модель из хвоста расшифровки, командная строка
        /// процесса сессии (по умолчанию с флагом bypass), `claude` для запуска и id новой сессии.
        var planDefaults = PlanChoice()
        var transcriptModel: String?
        var processArguments: [String]? = ["claude", "--allow-dangerously-skip-permissions"]
        var claude: URL? = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        var newSessionID = "new-session"
        /// Сколько «Открыто» висит в строке передачи.
        var linger: TimeInterval = 8
        /// Сколько стор ждёт, пока сессия перестанет «ждать», после ответа хука.
        var idleWait: TimeInterval = 0
        private(set) var transcriptReads: [URL] = []
        /// Файл настроек и папка копий: временные, настоящий `~/.claude/settings.json` сюда не попадает.
        let settingsFolder: URL
        let backups: URL
        var settingsURL: URL { settingsFolder.appendingPathComponent(".claude/settings.json") }
        static let command = ClaudeSettingsEdit.command(forExecutable: "/Applications/Cyclop.app/Contents/MacOS/Cyclop")
        lazy var store = ClaudeStore(
            folder: folder, isAlive: { [unowned self] pid, _ in alive.contains(pid) },
            opener: opener,
            settings: ClaudeSettingsFile(url: settingsURL, backups: { [backups] in backups }),
            command: Rig.command, listener: listener, now: { [unowned self] in moment },
            runner: runner, defaultPlanChoice: { [unowned self] in planDefaults },
            transcriptModel: { [unowned self] url in
                transcriptReads.append(url)
                return transcriptModel
            },
            processArguments: { [unowned self] _ in processArguments }, executable: { [unowned self] _ in claude },
            newSessionID: { [unowned self] in newSessionID }, waitForIdle: idleWait, handoffLinger: linger
        )

        init() throws {
            let base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("cyclop-claude-\(UUID().uuidString)", isDirectory: true)
            folder = base.appendingPathComponent("sessions", isDirectory: true)
            settingsFolder = base.appendingPathComponent("project", isDirectory: true)
            backups = base.appendingPathComponent("backups", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        /// Кладёт файл настроек (папку `.claude` заводит сам).
        func writeSettings(_ text: String) throws {
            try FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: settingsURL)
        }

        func settingsText() -> String? { try? String(contentsOf: settingsURL, encoding: .utf8) }

        /// Файл сессии; процесс считается живым, пока `alive: false` не сказано иначе.
        @discardableResult
        func write(
            _ pid: Int, status: String? = "idle", ago: TimeInterval = 0, name: String? = nil,
            cwd: String = "/Users/sato/pets/cyclop", entrypoint: String = "claude-vscode",
            kind: String = "interactive", alive isAlive: Bool = true, extra: [String: Any] = [:]
        ) throws -> URL {
            var body: [String: Any] = [
                "pid": pid, "procStart": "Mon Oct 12 08:31:22 2026", "sessionId": "session-\(pid)",
                "cwd": cwd, "entrypoint": entrypoint, "kind": kind,
            ]
            if let status { body["status"] = status }
            if let name { body["name"] = name }
            body["statusUpdatedAt"] = (moment.timeIntervalSince1970 - ago) * 1000
            body.merge(extra) { _, new in new }
            let url = folder.appendingPathComponent("\(pid).json")
            try JSONSerialization.data(withJSONObject: body).write(to: url)
            if isAlive { alive.insert(pid) }
            return url
        }
    }

    // MARK: - Строка списка

    @Test func aFileBecomesARowWithNameFolderPlaceAndState() throws {
        let rig = try Rig()
        try rig.write(7, status: "busy", ago: 90, name: "gro-factory-2a", cwd: "/Users/sato/pets/gro_factory")
        rig.store.reload()

        let row = try #require(rig.store.sessions.first)
        #expect(rig.store.sessions.count == 1)
        #expect(row.name == "gro-factory-2a")
        #expect(row.folder == "/Users/sato/pets/gro_factory")
        #expect(row.place == .editor)
        #expect(row.state == .working)
        #expect(row.since == ClaudeStoreTests.t0.addingTimeInterval(-90))
    }

    @Test func aSessionWithoutANameIsCalledByItsFolder() throws {
        let rig = try Rig()
        try rig.write(7, cwd: "/Users/sato/w/sense-docs")
        try rig.write(8, name: "", cwd: "/Users/sato/w/gro_factory")
        rig.store.reload()
        #expect(Set(rig.store.sessions.map(\.name)) == ["sense-docs", "gro_factory"])
    }

    @Test func theEntrypointSaysWhereTheSessionRuns() throws {
        let rig = try Rig()
        try rig.write(1, entrypoint: "claude-desktop", extra: ["hostSessionId": "local_abc"])
        try rig.write(2, entrypoint: "claude-vscode")
        try rig.write(3, entrypoint: "cli")
        rig.store.reload()
        let places = Dictionary(uniqueKeysWithValues: rig.store.sessions.map { ($0.pid, $0.place) })
        #expect(places == [1: .app, 2: .editor, 3: .terminal])
        #expect(rig.store.sessions.first { $0.pid == 1 }?.hostSessionID == "local_abc")
    }

    @Test func theStateStartedAtIsTheFallbackWhenNothingNewerIsThere() throws {
        let rig = try Rig()
        let url = try rig.write(7)
        var body = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        body["statusUpdatedAt"] = nil
        body["startedAt"] = (ClaudeStoreTests.t0.timeIntervalSince1970 - 500) * 1000
        try JSONSerialization.data(withJSONObject: body).write(to: url)
        rig.store.reload()
        #expect(rig.store.sessions.first?.since == ClaudeStoreTests.t0.addingTimeInterval(-500))
    }

    // MARK: - Что в список не попадает

    @Test func notWhatAPersonDrivesAndNotAliveAndNotParsedAreLeftOutAndTheRestStillShow() throws {
        let rig = try Rig()
        try rig.write(1, status: "busy")
        try rig.write(2, status: "busy", kind: "headless")
        try rig.write(3, status: nil)
        try rig.write(4, status: "busy", alive: false)
        try Data("{ not json".utf8).write(to: rig.folder.appendingPathComponent("5.json"))
        try Data().write(to: rig.folder.appendingPathComponent("6.json"))
        try Data("whatever".utf8).write(to: rig.folder.appendingPathComponent("1.abc123.key"))
        try rig.write(8, status: "idle")
        rig.store.reload()
        #expect(Set(rig.store.sessions.map(\.pid)) == [1, 8])
    }

    @Test func aFieldOfTheWrongTypeDoesNotCostTheSession() throws {
        let rig = try Rig()
        try rig.write(7, status: "busy", cwd: "/a/b", extra: ["name": 5, "waitingFor": ["x"]])
        rig.store.reload()
        #expect(rig.store.sessions.first?.name == "b")
    }

    @Test func theProcessIdFallsBackToTheFileName() throws {
        let rig = try Rig()
        let url = try rig.write(42)
        var body = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        body["pid"] = nil
        try JSONSerialization.data(withJSONObject: body).write(to: url)
        rig.store.reload()
        #expect(rig.store.sessions.first?.pid == 42)
    }

    @Test func anUnknownStateReadsAsWaiting() throws {
        let rig = try Rig()
        try rig.write(1, status: "dialog open", extra: ["waitingFor": "dialog open"])
        rig.store.reload()
        #expect(rig.store.sessions.first?.state == .waiting)
        #expect(rig.store.waitingCount == 1)
    }

    // MARK: - Порядок

    @Test func waitingFirstThenWorkingThenRecentIdle() throws {
        let rig = try Rig()
        try rig.write(1, status: "idle", ago: 60)
        try rig.write(2, status: "busy", ago: 100)
        try rig.write(3, status: "waiting", ago: 30)
        try rig.write(4, status: "idle", ago: 10)
        try rig.write(5, status: "busy", ago: 5)
        try rig.write(6, status: "waiting", ago: 300)
        rig.store.reload()
        // Ждущие: дольше ждёт — выше. Работающие и свободные: свежее — выше.
        #expect(rig.store.sessions.map(\.pid) == [6, 3, 5, 2, 4, 1])
        #expect(rig.store.waitingCount == 2)
    }

    @Test func idleSessionsOfTheLastDayAreAllListedByRecency() throws {
        let rig = try Rig()
        try rig.write(1, status: "idle", ago: 80_000)
        try rig.write(2, status: "idle", ago: 7200)
        try rig.write(3, status: "idle", ago: 60)
        rig.store.reload()
        // Старше часа — тоже в списке, свёртки нет: свежее — выше.
        #expect(rig.store.sessions.map(\.pid) == [3, 2, 1])
    }

    @Test func idleSessionsOlderThanADayAreNotListed() throws {
        let rig = try Rig()
        try rig.write(1, status: "idle", ago: 200_000)
        try rig.write(2, status: "idle", ago: 90_000)
        try rig.write(3, status: "idle", ago: 60)
        rig.store.reload()
        #expect(rig.store.sessions.map(\.pid) == [3])
    }

    @Test func aDayIsTheBoundaryAndItBelongsToTheList() throws {
        let rig = try Rig()
        try rig.write(1, status: "idle", ago: 86_400)
        try rig.write(2, status: "idle", ago: 86_401)
        rig.store.reload()
        #expect(rig.store.sessions.map(\.pid) == [1])
    }

    @Test func aSessionAgesOutOfTheListAsTheClockMoves() throws {
        let rig = try Rig()
        try rig.write(1, status: "idle", ago: 86_000)
        rig.store.reload()
        #expect(rig.store.sessions.map(\.pid) == [1])
        rig.moment = rig.moment.addingTimeInterval(500)
        rig.store.reload()
        #expect(rig.store.sessions.isEmpty)
    }

    @Test func waitingAndWorkingSessionsStayWhateverTheirAge() throws {
        let rig = try Rig()
        try rig.write(1, status: "waiting", ago: 300_000)
        try rig.write(2, status: "busy", ago: 200_000)
        try rig.write(3, status: "idle", ago: 200_000)
        rig.store.reload()
        #expect(rig.store.sessions.map(\.pid) == [1, 2])
        #expect(rig.store.waitingCount == 1)
    }

    // MARK: - Уходят из списка

    @Test func aRemovedFileAndADeadProcessLeaveAtTheNextReading() throws {
        let rig = try Rig()
        let gone = try rig.write(1, status: "busy")
        try rig.write(2, status: "busy")
        try rig.write(3, status: "busy")
        rig.store.reload()
        #expect(rig.store.sessions.count == 3)

        try FileManager.default.removeItem(at: gone)
        rig.alive.remove(2)
        rig.store.reload()
        #expect(rig.store.sessions.map(\.pid) == [3])
    }

    @Test func aMissingFolderIsAnEmptyList() throws {
        let rig = try Rig()
        try FileManager.default.removeItem(at: rig.folder)
        rig.store.reload()
        #expect(rig.store.sessions.isEmpty)
    }

    @Test func endingBackgroundWorkEmptiesTheList() throws {
        let rig = try Rig()
        try rig.write(1, status: "busy")
        rig.store.beginBackground()
        #expect(rig.store.sessions.count == 1)
        rig.store.endBackground()
        #expect(rig.store.sessions.isEmpty)
    }

    // MARK: - Открыть в Claude

    private static let cursor = ClaudeHostApp(url: URL(fileURLWithPath: "/Applications/Cursor.app"), urlScheme: "cursor")
    private static let terminal = ClaudeHostApp(url: URL(fileURLWithPath: "/Applications/Ghostty.app"), urlScheme: nil)

    @Test func aSessionInTheClaudeAppOpensByTheAppsLinkWithItsOwnId() throws {
        let rig = try Rig()
        try rig.write(1, entrypoint: "claude-desktop", extra: ["hostSessionId": "local_1f2e"])
        rig.store.reload()
        rig.store.openInClaude(try #require(rig.store.sessions.first))
        #expect(rig.opener.opened.map(\.absoluteString) == ["claude://code/continue?session=local_1f2e"])
        #expect(rig.opener.broughtForward.isEmpty)
    }

    @Test func aSessionInAnEditorOpensByTheEditorsOwnScheme() throws {
        let rig = try Rig()
        try rig.write(2, entrypoint: "claude-vscode")
        rig.opener.hosts[2] = Self.cursor
        rig.store.reload()
        rig.store.openInClaude(try #require(rig.store.sessions.first))
        #expect(rig.opener.opened.map(\.absoluteString) == ["cursor://anthropic.claude-code/open?session=session-2"])
    }

    @Test func anEditorWithoutALinkSchemeIsOnlyBroughtForward() throws {
        let rig = try Rig()
        try rig.write(2, entrypoint: "claude-vscode")
        let unknown = ClaudeHostApp(url: URL(fileURLWithPath: "/Applications/Zed.app"), urlScheme: nil)
        rig.opener.hosts[2] = unknown
        rig.store.reload()
        rig.store.openInClaude(try #require(rig.store.sessions.first))
        #expect(rig.opener.opened.isEmpty)
        #expect(rig.opener.broughtForward == [unknown])
    }

    @Test func aTerminalSessionShowsItsTabAndDoesNotBringTheAppForwardToo() throws {
        let rig = try Rig()
        try rig.write(3, entrypoint: "cli")
        rig.opener.hosts[3] = Self.terminal
        rig.opener.tabFound = true
        rig.store.reload()
        rig.store.openInClaude(try #require(rig.store.sessions.first))
        #expect(rig.opener.opened.isEmpty)
        #expect(rig.opener.focused == [3])
        #expect(rig.opener.broughtForward.isEmpty)
    }

    @Test func aTerminalSessionWhoseTabIsNotShownBringsItsTerminalForward() throws {
        let rig = try Rig()
        try rig.write(3, entrypoint: "cli")
        rig.opener.hosts[3] = Self.terminal
        rig.opener.tabFound = false
        rig.store.reload()
        rig.store.openInClaude(try #require(rig.store.sessions.first))
        #expect(rig.opener.opened.isEmpty)
        #expect(rig.opener.focused == [3])
        #expect(rig.opener.broughtForward == [Self.terminal])
    }

    @Test func aSessionWhoseOwnerCannotBeFoundOpensNothing() throws {
        let rig = try Rig()
        try rig.write(2, entrypoint: "claude-vscode")
        try rig.write(3, entrypoint: "cli")
        try rig.write(4, entrypoint: "claude-desktop")
        rig.store.reload()
        for session in rig.store.sessions { rig.store.openInClaude(session) }
        #expect(rig.opener.opened.isEmpty)
        #expect(rig.opener.broughtForward.isEmpty)
        #expect(rig.opener.focused.isEmpty)
    }

    @Test func aClaudeAppSessionWithoutTheAppsIdBringsTheAppForward() throws {
        let rig = try Rig()
        try rig.write(4, entrypoint: "claude-desktop")
        let app = ClaudeHostApp(url: URL(fileURLWithPath: "/Applications/Claude.app"), urlScheme: "claude")
        rig.opener.hosts[4] = app
        rig.store.reload()
        rig.store.openInClaude(try #require(rig.store.sessions.first))
        #expect(rig.opener.opened.isEmpty)
        #expect(rig.opener.broughtForward == [app])
    }
}
