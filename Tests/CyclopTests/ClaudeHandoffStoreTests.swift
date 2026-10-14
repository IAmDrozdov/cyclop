import Foundation
import Testing
@testable import Cyclop

/// Тесты передачи плана в `ClaudeStore`: выбор у запроса, маршрут, новая сессия в терминале, в приложении и в
/// редакторе. Запуск `claude`, AppleScript и открытие ссылок — подделки; настоящие файлы Claude не участвуют.
@MainActor
struct ClaudeHandoffStoreTests {

    private typealias Rig = ClaudeStoreTests.Rig

    private static let terminalApp = ClaudeHostApp(
        url: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), urlScheme: nil, bundleID: "com.apple.Terminal")
    private static let cursor = ClaudeHostApp(
        url: URL(fileURLWithPath: "/Applications/Cursor.app"), urlScheme: "cursor", bundleID: "com.todesktop.cursor")

    private static func plan(
        pid: Int = 7, planFile: String? = "~/.claude/plans/idea.md", agent: String? = nil, transcript: String? = "/tmp/t.jsonl"
    ) -> String {
        let file = planFile.map { #","planFilePath":"\#($0)""# } ?? ""
        let agentID = agent.map { #","agent_id":"\#($0)""# } ?? ""
        let path = transcript.map { #","transcript_path":"\#($0)""# } ?? ""
        return ##"{"session_id":"session-\##(pid)","hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode","cwd":"/Users/sato/work","permission_mode":"plan"\##(path)\##(agentID),"tool_input":{"plan":"# План\n\nСделать"\##(file)}}"##
    }

    private static let denial =
        #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Approved in Cyclop; the plan goes on in a new session.","interrupt":true}}}"#

    /// Подключённый Cyclop и одна ждущая сессия в нужном месте.
    private func ready(
        entrypoint: String, host: ClaudeHostApp? = nil, configure: (Rig) -> Void = { _ in }
    ) throws -> Rig {
        let rig = try Rig()
        configure(rig)
        try rig.writeSettings(try ClaudeSettingsEdit.connecting("{}", command: Rig.command))
        try rig.write(7, status: "waiting", name: "gro-factory", cwd: "/Users/sato/work", entrypoint: entrypoint)
        rig.opener.hosts[7] = host
        rig.store.beginBackground()
        return rig
    }

    private func arrive(_ rig: Rig, _ body: String = ClaudeHandoffStoreTests.plan()) throws -> (id: UUID, relay: ClaudeStoreTests.FakeRelay) {
        let relay = rig.listener.arrive(body)
        return (try #require(rig.store.requests.first?.id), relay)
    }

    private func choose(
        _ rig: Rig, _ id: UUID, _ context: PlanChoice.Context, _ model: PlanChoice.ModelChoice,
        effort: PlanChoice.Effort = .medium, mode: PlanChoice.Mode = .bypassPermissions
    ) {
        rig.store.setPlanChoice(PlanChoice(context: context, model: model, effort: effort, mode: mode), of: id)
    }

    private static let plain =
        "Implement the plan in ~/.claude/plans/idea.md. If you need specific details from the planning "
        + "(exact code, error messages, findings), read the planning session's transcript: /tmp/t.jsonl."
    private static let ready =
        "The plan to implement when the owner says go is in ~/.claude/plans/idea.md. If you need specific details from the "
        + "planning (exact code, error messages, findings), read the planning session's transcript then: /tmp/t.jsonl."
        + "\n\nDo not use any tool and do not change anything now: reply only with the word Ready. "
        + "The owner will start the work in Claude."
    private static let instruction =
        "/compact Keep what the approved plan in ~/.claude/plans/idea.md needs: decisions, findings, file paths and the owner's remarks."

    /// Те же тексты в одинарных кавычках оболочки: `'` внутри пишется `'\\''`.
    private static let shellPlain = plain.replacingOccurrences(of: "'", with: "'\\''")
    private static let shellInstruction = instruction.replacingOccurrences(of: "'", with: "'\\''")

    // MARK: - Выбор

    @Test func theChoiceStartsFromTheDefaultsAndCanBeChangedPerRequest() throws {
        let rig = try ready(entrypoint: "claude-desktop") { $0.planDefaults = PlanChoice(context: .compact, model: .same, effort: .high, mode: .auto) }
        let (id, _) = try arrive(rig)

        #expect(rig.store.planChoice(of: id) == PlanChoice(context: .compact, model: .same, effort: .high, mode: .auto))
        choose(rig, id, .clear, .sonnet, effort: .low, mode: .acceptEdits)

        #expect(rig.store.planChoice(of: id) == PlanChoice(context: .clear, model: .sonnet, effort: .low, mode: .acceptEdits))
        #expect(rig.planDefaults.context == .compact)
    }

    @Test func eachRequestHasItsOwnChoice() throws {
        let rig = try ready(entrypoint: "claude-desktop")
        let first = try arrive(rig)
        rig.listener.arrive(Self.plan())
        let second = try #require(rig.store.requests.last?.id)

        choose(rig, first.id, .keep, .same)

        #expect(rig.store.planChoice(of: first.id).context == .keep)
        #expect(rig.store.planChoice(of: second).context == .clear)
    }

    @Test func theStoreSaysWhatItKnowsOfTheSession() throws {
        let rig = try ready(entrypoint: "claude-desktop") { $0.transcriptModel = "claude-opus-5-5" }
        let (id, _) = try arrive(rig)

        #expect(rig.store.sessionModel(of: id) == "claude-opus-5-5")
        #expect(rig.store.bypassAllowed(of: id))
        #expect(rig.store.handoffUnavailable(of: id) == nil)
        #expect(rig.transcriptReads == [URL(fileURLWithPath: "/tmp/t.jsonl")])
    }

    @Test func withoutATranscriptPathTheUsualOneIsRead() throws {
        let rig = try ready(entrypoint: "claude-desktop")
        _ = try arrive(rig, Self.plan(transcript: nil))

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(rig.transcriptReads == [URL(fileURLWithPath: "\(home)/.claude/projects/-Users-sato-work/session-7.jsonl")])
    }

    // MARK: - Где передачи нет

    @Test func whereAHandoffIsNotOfferedTheChoiceStaysInThisSession() throws {
        let cases: [(String, ClaudeHostApp?, String, HandoffUnavailable)] = [
            ("claude-desktop", nil, Self.plan(planFile: nil), .noPlanFile),
            ("claude-desktop", nil, Self.plan(agent: "agent-1"), .subagent),
            ("cli", ClaudeHostApp(url: URL(fileURLWithPath: "/Applications/Ghostty.app"), urlScheme: nil, bundleID: "com.mitchellh.ghostty"), Self.plan(), .unknownTerminal),
            ("claude-vscode", ClaudeHostApp(url: URL(fileURLWithPath: "/Applications/Zed.app"), urlScheme: nil), Self.plan(), .noURLScheme),
        ]
        for (entrypoint, host, body, reason) in cases {
            let rig = try ready(entrypoint: entrypoint, host: host)
            let (id, relay) = try arrive(rig, body)

            #expect(rig.store.handoffUnavailable(of: id) == reason)
            #expect(rig.store.planChoice(of: id).context == .keep && rig.store.planChoice(of: id).model == .same)
            #expect(rig.store.planRoute(of: id) == .inPlace)
            rig.store.approve(id)

            #expect(relay.replies.count == 1 && relay.replies[0].contains(#""updatedPermissions""#))
            #expect(rig.store.handoffs.isEmpty && rig.runner.calls.isEmpty && rig.opener.typed.isEmpty)
        }
    }

    // MARK: - Маршрут

    @Test func keepWithSonnetOnSonnetStaysInPlaceAndOnOpusOrUnknownHandsOff() throws {
        for (model, route) in [("claude-sonnet-5-5", PlanRoute.inPlace), ("claude-opus-5-5", .handoff), (nil, .handoff)] {
            let rig = try ready(entrypoint: "claude-desktop") { $0.transcriptModel = model }
            let (id, _) = try arrive(rig)
            choose(rig, id, .keep, .sonnet)

            #expect(rig.store.planRoute(of: id) == route)
        }
    }

    @Test func keepWithTheSameModelApprovesInThisSessionWithTheMode() throws {
        let rig = try ready(entrypoint: "claude-desktop")
        let (id, relay) = try arrive(rig)
        choose(rig, id, .keep, .same, mode: .auto)

        rig.store.approve(id)

        #expect(relay.replies.count == 1)
        #expect(relay.replies[0].contains(#""updatedPermissions":[{"type":"setMode","mode":"auto","destination":"session"}]"#))
        #expect(rig.store.handoffs.isEmpty && rig.runner.calls.isEmpty)
    }

    @Test func aBypassShownAsAcceptEditsComesBackWhenTheRouteBecomesAHandoff() throws {
        let rig = try ready(entrypoint: "claude-desktop") { $0.processArguments = ["claude"] }
        let (id, _) = try arrive(rig)
        choose(rig, id, .keep, .same)
        #expect(rig.store.planChoice(of: id).mode == .acceptEdits)

        // Владелец трогает только контекст: выбранный режим не теряется.
        var changed = rig.store.planChoice(of: id)
        changed.context = .clear
        rig.store.setPlanChoice(changed, of: id)

        #expect(rig.store.planChoice(of: id).mode == .bypassPermissions)
    }

    // MARK: - Терминал

    @Test func aTerminalHandoffDeniesThenTypesTheCommandInTheTerminal() async throws {
        let rig = try ready(entrypoint: "cli", host: Self.terminalApp) { $0.transcriptModel = "claude-opus-5-5" }
        let (id, relay) = try arrive(rig)
        choose(rig, id, .compact, .sonnet, effort: .low, mode: .acceptEdits)

        rig.store.approve(id)

        #expect(relay.replies == [Self.denial])
        #expect(rig.store.handoffs.map(\.phase) == [.preparing])
        await rig.store.waitForHandoffs()

        let clean = "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_CHILD_SESSION claude"
        let expected =
            "cd '/Users/sato/work' && \(clean) -p --resume 'session-7' --fork-session --session-id 'new-session' '\(Self.shellInstruction)' > /dev/null"
            + " && \(clean) --resume 'new-session' --model sonnet --effort low --permission-mode acceptEdits '\(Self.shellPlain)'"
        #expect(rig.opener.typed.map(\.command) == [expected])
        #expect(rig.opener.typed.map(\.pid) == [7])
        #expect(rig.store.handoffs.map(\.phase) == [.opened])
        #expect(rig.store.handoffs.first?.place == .terminal)
        #expect(rig.store.handoffs.first?.sessionName == "gro-factory")
        #expect(rig.runner.calls.isEmpty && rig.opener.opened.isEmpty)
    }

    @Test func aTerminalScriptThatFailsOtherwiseIsNotReportedAsAutomationDenied() async throws {
        let rig = try ready(entrypoint: "cli", host: Self.terminalApp)
        rig.opener.typingResult = .failed
        let (id, _) = try arrive(rig)

        rig.store.approve(id)
        await rig.store.waitForHandoffs()

        #expect(rig.store.handoffs.map(\.phase) == [.failed(.terminalFailed)])
        #expect(rig.store.handoffs.first?.command != nil)
    }

    @Test func aTerminalThatRefusesShowsAFailedHandoffWithTheCommandToCopy() async throws {
        let rig = try ready(entrypoint: "cli", host: Self.terminalApp)
        rig.opener.typingResult = .automationDenied
        let (id, _) = try arrive(rig)

        rig.store.approve(id)
        await rig.store.waitForHandoffs()

        let status = try #require(rig.store.handoffs.first)
        #expect(status.phase == .failed(.automationDenied))
        rig.store.copyCommand(of: status.id)
        #expect(rig.opener.copied == [rig.opener.typed[0].command])
        rig.store.dismissHandoff(status.id)
        #expect(rig.store.handoffs.isEmpty)
    }

    // MARK: - Ожидание, пока сессия перестанет ждать

    @Test func theHandoffWaitsForTheSessionToLeaveWaiting() async throws {
        let rig = try ready(entrypoint: "cli", host: Self.terminalApp) { $0.idleWait = 5 }
        let (id, _) = try arrive(rig)

        rig.store.approve(id)
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.opener.typed.isEmpty)
        #expect(rig.store.handoffs.map(\.phase) == [.preparing])

        try rig.write(7, status: "idle", name: "gro-factory", cwd: "/Users/sato/work", entrypoint: "cli")
        await rig.store.waitForHandoffs()

        #expect(rig.opener.typed.count == 1)
        #expect(rig.store.handoffs.map(\.phase) == [.opened])
    }

    @Test func theHandoffGoesAheadAfterTheDeadlineWhenTheSessionStaysWaiting() async throws {
        let rig = try ready(entrypoint: "cli", host: Self.terminalApp) { $0.idleWait = 0.5 }
        let (id, _) = try arrive(rig)
        let clock = ContinuousClock()
        let started = clock.now

        rig.store.approve(id)
        await rig.store.waitForHandoffs()

        #expect(clock.now - started >= .milliseconds(450))
        #expect(rig.opener.typed.count == 1)
        #expect(rig.store.handoffs.map(\.phase) == [.opened])
    }

    // MARK: - Приложение и редактор

    @Test func anAppHandoffRunsTheStepsThenOpensTheSessionInTheApp() async throws {
        let rig = try ready(entrypoint: "claude-desktop") { $0.transcriptModel = "claude-opus-5-5" }
        let (id, relay) = try arrive(rig)
        choose(rig, id, .compact, .sonnet, effort: .xhigh, mode: .bypassPermissions)

        rig.store.approve(id)
        #expect(relay.replies == [Self.denial])
        await rig.store.waitForHandoffs()

        let work = URL(fileURLWithPath: "/Users/sato/work", isDirectory: true)
        let claude = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        #expect(
            rig.runner.calls == [
                .init(
                    executable: claude,
                    arguments: ["-p", "--resume", "session-7", "--fork-session", "--session-id", "new-session", Self.instruction],
                    folder: work),
                .init(
                    executable: claude,
                    arguments: [
                        "-p", "--resume", "new-session", "--model", "sonnet", "--effort", "xhigh", "--permission-mode",
                        "acceptEdits", "--max-turns", "1", "--settings", ClaudeHandoff.noToolSettings, Self.ready,
                    ], folder: work),
            ])
        #expect(rig.opener.opened == [URL(string: "claude://resume?session=new-session")!])
        #expect(rig.store.handoffs.map(\.phase) == [.opened])
        #expect(rig.opener.typed.isEmpty)
    }

    @Test func theRunnerGetsAnEnvironmentWithoutTheClaudeSessionVariables() async throws {
        let rig = try ready(entrypoint: "claude-desktop")
        let (id, _) = try arrive(rig)

        rig.store.approve(id)
        await rig.store.waitForHandoffs()

        let names = Set(rig.runner.environment.keys)
        #expect(!names.contains("CLAUDECODE") && !names.contains("CLAUDE_CODE_ENTRYPOINT") && !names.contains("CLAUDE_CODE_CHILD_SESSION"))
        #expect(names.contains("PATH"))
    }

    @Test func anEditorHandoffOpensTheEditorsLink() async throws {
        let rig = try ready(entrypoint: "claude-vscode", host: Self.cursor)
        let (id, _) = try arrive(rig)
        choose(rig, id, .clear, .sonnet)

        rig.store.approve(id)
        await rig.store.waitForHandoffs()

        // Импорт редактора не проверен: ход подготовки спрашивает, какой бы режим ни был выбран.
        #expect(
            rig.runner.calls.map(\.arguments) == [
                [
                    "-p", "--session-id", "new-session", "--model", "sonnet", "--effort", "medium", "--permission-mode", "default",
                    "--max-turns", "1", "--settings", ClaudeHandoff.noToolSettings, Self.ready,
                ]
            ])
        #expect(rig.opener.opened == [URL(string: "cursor://anthropic.claude-code/open?session=new-session")!])
        #expect(rig.store.handoffs.map(\.phase) == [.opened])
    }

    @Test func aFailingStepShowsAFailedHandoffAndOpensNothing() async throws {
        let rig = try ready(entrypoint: "claude-desktop")
        rig.runner.answer(
            ClaudeRun(status: 0, standardError: ""), ClaudeRun(status: 1, standardError: "warning\nError: not logged in\n\n"))
        let (id, _) = try arrive(rig)
        choose(rig, id, .compact, .sonnet)

        rig.store.approve(id)
        await rig.store.waitForHandoffs()

        #expect(rig.runner.calls.count == 2)
        #expect(rig.store.handoffs.map(\.phase) == [.failed(.step("Error: not logged in"))])
        #expect(rig.opener.opened.isEmpty)
    }

    @Test func aFailureWithoutAnyTextAndATimeoutHaveTheirOwnReasons() async throws {
        let rig = try ready(entrypoint: "claude-desktop")
        rig.runner.answer(ClaudeRun(status: 3, standardError: "\n"))
        let (id, _) = try arrive(rig)
        rig.store.approve(id)
        await rig.store.waitForHandoffs()
        #expect(rig.store.handoffs.map(\.phase) == [.failed(.exitStatus(3))])

        let slow = try ready(entrypoint: "claude-desktop")
        slow.runner.answer(ClaudeRun(status: -1, standardError: "", timedOut: true))
        let (slowID, _) = try arrive(slow)
        slow.store.approve(slowID)
        await slow.store.waitForHandoffs()
        #expect(slow.store.handoffs.map(\.phase) == [.failed(.timedOut)])
    }

    /// Без `claude` передача не предлагается с самого прихода плана: ответ хука не отбрасывается зря.
    @Test func withoutAClaudeExecutableTheHandoffIsNotOfferedAndTheApprovalStaysInPlace() async throws {
        for (entrypoint, host) in [("claude-desktop", nil), ("claude-vscode", Self.cursor)] {
            let rig = try ready(entrypoint: entrypoint, host: host) { $0.claude = nil }
            let (id, relay) = try arrive(rig)

            #expect(rig.store.handoffUnavailable(of: id) == .noExecutable)
            #expect(rig.store.planRoute(of: id) == .inPlace)
            rig.store.approve(id)
            await rig.store.waitForHandoffs()

            #expect(relay.replies.count == 1 && relay.replies[0].contains(#""updatedPermissions""#))
            #expect(rig.store.handoffs.isEmpty && rig.runner.calls.isEmpty && rig.opener.opened.isEmpty)
        }
    }

    @Test func aTerminalHandoffNeedsNoClaudeExecutable() throws {
        let rig = try ready(entrypoint: "cli", host: Self.terminalApp) { $0.claude = nil }
        let (id, _) = try arrive(rig)

        #expect(rig.store.handoffUnavailable(of: id) == nil)
    }

    @Test func aControlCharacterInTheFolderKeepsTheTerminalHandoffOff() throws {
        let rig = try ready(entrypoint: "cli", host: Self.terminalApp)
        let body = Self.plan().replacingOccurrences(of: "/Users/sato/work", with: #"/tmp/a\u0015touch pwned\u000a"#)
        let (id, relay) = try arrive(rig, body)

        #expect(rig.store.handoffUnavailable(of: id) == .controlCharacters)
        rig.store.approve(id)

        #expect(relay.replies.count == 1 && relay.replies[0].contains(#""updatedPermissions""#))
        #expect(rig.opener.typed.isEmpty)
    }

    @Test func aSessionThatCannotBeLinkedToIsNotReportedAsAMissingExecutable() async throws {
        let rig = try ready(entrypoint: "claude-vscode", host: ClaudeHostApp(url: Self.cursor.url, urlScheme: "1x"))
        let (id, _) = try arrive(rig)
        choose(rig, id, .clear, .sonnet)

        rig.store.approve(id)
        await rig.store.waitForHandoffs()

        #expect(rig.runner.calls.count == 1)
        #expect(rig.store.handoffs.map(\.phase) == [.failed(.noLink)])
        #expect(rig.opener.opened.isEmpty)
    }

    // MARK: - Строка передачи

    @Test func anOpenedHandoffGoesAwayByItself() async throws {
        let rig = try ready(entrypoint: "claude-desktop") { $0.linger = 0.05 }
        let (id, _) = try arrive(rig)
        rig.store.approve(id)
        await rig.store.waitForHandoffs()
        #expect(rig.store.handoffs.map(\.phase) == [.opened])

        try await Task.sleep(for: .milliseconds(400))

        #expect(rig.store.handoffs.isEmpty)
    }

    @Test func aFailedHandoffStaysUntilDismissed() async throws {
        let rig = try ready(entrypoint: "claude-desktop") { $0.linger = 0.05 }
        rig.runner.answer(ClaudeRun(status: 1, standardError: "Error: no auth"))
        let (id, _) = try arrive(rig)
        rig.store.approve(id)
        await rig.store.waitForHandoffs()

        try await Task.sleep(for: .milliseconds(300))

        let status = try #require(rig.store.handoffs.first)
        rig.store.dismissHandoff(status.id)
        #expect(rig.store.handoffs.isEmpty)
    }

    @Test func copyCommandOfAHandoffWithoutOneCopiesNothing() async throws {
        let rig = try ready(entrypoint: "claude-desktop")
        let (id, _) = try arrive(rig)
        rig.store.approve(id)
        await rig.store.waitForHandoffs()
        let status = try #require(rig.store.handoffs.first)

        rig.store.copyCommand(of: status.id)

        #expect(rig.opener.copied.isEmpty)
    }

    // MARK: - Память

    @Test func aPlanAndItsHandoffLeaveNoFileWithTheirText() async throws {
        let rig = try ready(entrypoint: "claude-desktop")
        let (id, _) = try arrive(rig)
        rig.store.approve(id)
        await rig.store.waitForHandoffs()

        let base = rig.folder.deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        for file in files where !file.hasDirectoryPath {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            #expect(!text.contains("idea.md") && !text.contains("new-session"))
        }
    }
}
