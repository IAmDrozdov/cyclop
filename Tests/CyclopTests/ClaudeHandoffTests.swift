import Foundation
import Testing
@testable import Cyclop

/// Чистая часть передачи плана: маршрут, тексты, команды, окружение, модель из хвоста расшифровки.
/// Ни `claude`, ни AppleScript, ни настоящих файлов Claude здесь нет.
struct ClaudeHandoffTests {

    private static func choice(
        _ context: PlanChoice.Context, _ model: PlanChoice.ModelChoice, effort: PlanChoice.Effort = .medium,
        mode: PlanChoice.Mode = .bypassPermissions
    ) -> PlanChoice {
        PlanChoice(context: context, model: model, effort: effort, mode: mode)
    }

    private static func handoff(_ choice: PlanChoice, model: String? = "claude-opus-5-5") -> ClaudeHandoff {
        ClaudeHandoff(
            choice: choice, sessionModel: model, folder: "/Users/sato/pets/cyclop", sessionID: "old-id",
            newSessionID: "new-id", planFile: "~/.claude/plans/idea.md", transcript: "/Users/sato/.claude/projects/p/old-id.jsonl")
    }

    private static let plain =
        "Implement the plan in ~/.claude/plans/idea.md. If you need specific details from the planning "
        + "(exact code, error messages, findings), read the planning session's transcript: /Users/sato/.claude/projects/p/old-id.jsonl."
    private static let ready =
        "The plan to implement when the owner says go is in ~/.claude/plans/idea.md. If you need specific details from the "
        + "planning (exact code, error messages, findings), read the planning session's transcript then: "
        + "/Users/sato/.claude/projects/p/old-id.jsonl.\n\nDo not use any tool and do not change anything now: reply only with "
        + "the word Ready. The owner will start the work in Claude."
    private static let instruction =
        "/compact Keep what the approved plan in ~/.claude/plans/idea.md needs: decisions, findings, file paths and the owner's remarks."
    /// Те же тексты в одинарных кавычках оболочки: `'` внутри пишется `'\\''`.
    private static let shellPlain = plain.replacingOccurrences(of: "'", with: "'\\''")
    private static let shellInstruction = instruction.replacingOccurrences(of: "'", with: "'\\''")

    private static let clean = "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_CHILD_SESSION claude"

    // MARK: - Маршрут

    @Test func theRouteFollowsTheContextAndTheModel() {
        let opus = "claude-opus-5-5"
        let sonnet = "claude-sonnet-5-5"
        #expect(Self.choice(.keep, .same).route(sessionModel: opus) == .inPlace)
        #expect(Self.choice(.keep, .sonnet).route(sessionModel: opus) == .handoff)
        #expect(Self.choice(.keep, .sonnet).route(sessionModel: sonnet) == .inPlace)
        #expect(Self.choice(.compact, .same).route(sessionModel: opus) == .handoff)
        #expect(Self.choice(.compact, .sonnet).route(sessionModel: sonnet) == .handoff)
        #expect(Self.choice(.clear, .same).route(sessionModel: sonnet) == .handoff)
        #expect(Self.choice(.keep, .sonnet).route(sessionModel: nil) == .handoff)
        #expect(Self.choice(.keep, .same).route(sessionModel: nil) == .inPlace)
    }

    @Test func theDefaultsAreClearSonnetMediumBypass() {
        #expect(PlanChoice() == Self.choice(.clear, .sonnet))
        #expect(PlanChoice(ConfigStore.PlanApproval()) == PlanChoice())
    }

    @Test func settingsValuesThisVersionDoesNotKnowReadAsTheDefaults() {
        var config = ConfigStore.PlanApproval()
        config.context = "shrink"
        config.model = "opus"
        config.effort = "max"
        config.mode = "dontAsk"

        let choice = PlanChoice(config)

        #expect(choice == Self.choice(.clear, .sonnet, effort: .max))
        #expect(PlanChoice(choice.config) == choice)
    }

    // MARK: - Предложена ли передача

    private func unavailable(
        planFile: String? = "plan.md", agent: String? = nil, folder: String = "/x", place: ClaudeSession.Place = .app,
        bundle: String? = nil, scheme: String? = nil, typed: [String] = [], hasExecutable: Bool = true
    ) -> HandoffUnavailable? {
        ClaudeHandoff.unavailable(
            planFile: planFile, agentID: agent, folder: folder, place: place, hostBundleID: bundle, hostURLScheme: scheme,
            typed: typed, hasExecutable: hasExecutable)
    }

    @Test func aHandoffIsNotOfferedWithoutAPlanFileForASubagentOrWithoutAFolder() {
        #expect(unavailable() == nil)
        #expect(unavailable(planFile: nil) == .noPlanFile)
        #expect(unavailable(planFile: "") == .noPlanFile)
        #expect(unavailable(agent: "agent-1") == .subagent)
        #expect(unavailable(folder: "") == .noFolder)
    }

    @Test func aTerminalNeedsTerminalOrITermAndAnEditorNeedsAScheme() {
        #expect(unavailable(place: .terminal, bundle: "com.apple.Terminal") == nil)
        #expect(unavailable(place: .terminal, bundle: "com.googlecode.iterm2") == nil)
        #expect(unavailable(place: .terminal, bundle: "com.mitchellh.ghostty") == .unknownTerminal)
        #expect(unavailable(place: .terminal, bundle: nil) == .unknownTerminal)
        #expect(unavailable(place: .editor, scheme: "cursor") == nil)
        #expect(unavailable(place: .editor, scheme: nil) == .noURLScheme)
        #expect(unavailable(place: .editor) == .noURLScheme)
    }

    @Test func aControlCharacterInATerminalValueMakesTheHandoffUnavailable() {
        let terminal = "com.apple.Terminal"
        #expect(unavailable(folder: "/a\u{15}b", place: .terminal, bundle: terminal) == .controlCharacters)
        #expect(unavailable(planFile: "p\n.md", place: .terminal, bundle: terminal) == .controlCharacters)
        #expect(unavailable(place: .terminal, bundle: terminal, typed: ["id", "/t\u{7f}.jsonl"]) == .controlCharacters)
        #expect(unavailable(place: .terminal, bundle: terminal, typed: ["id", "/t.jsonl"]) == nil)
        // Аргументы `claude -p` не проходят через строку ввода: там такие знаки безвредны.
        #expect(unavailable(folder: "/a\u{15}b", place: .app) == nil)
    }

    @Test func aMissingClaudeExecutableMakesAnAppOrEditorHandoffUnavailable() {
        #expect(unavailable(place: .app, hasExecutable: false) == .noExecutable)
        #expect(unavailable(place: .editor, scheme: "cursor", hasExecutable: false) == .noExecutable)
        #expect(unavailable(place: .editor, scheme: nil, hasExecutable: false) == .noURLScheme)
        #expect(unavailable(place: .terminal, bundle: "com.apple.Terminal", hasExecutable: false) == nil)
    }

    // MARK: - Тексты

    @Test func thePromptNamesThePlanAndTheTranscriptAndAPreparedOneDoesNothing() {
        let handoff = Self.handoff(PlanChoice())

        #expect(handoff.prompt(prepared: false) == Self.plain)
        #expect(handoff.prompt(prepared: true) == Self.ready)
        #expect(handoff.compactInstruction == Self.instruction)
    }

    // MARK: - Команда для терминала

    @Test func clearStartsANewSessionOnSonnet() {
        let command = Self.handoff(Self.choice(.clear, .sonnet)).shellCommand

        #expect(
            command
                == "cd '/Users/sato/pets/cyclop' && \(Self.clean) --model sonnet --effort medium --permission-mode bypassPermissions '\(Self.shellPlain)'"
        )
    }

    @Test func clearWithTheSameModelNamesTheSessionsModelWhenKnown() {
        let known = Self.handoff(Self.choice(.clear, .same, effort: .high, mode: .acceptEdits)).shellCommand
        let unknown = Self.handoff(Self.choice(.clear, .same), model: nil).shellCommand

        #expect(known.contains(" claude --model claude-opus-5-5 --effort high --permission-mode acceptEdits '"))
        #expect(unknown.contains(" claude --effort medium --permission-mode bypassPermissions '"))
    }

    @Test func aModelIdThatIsNotPlainIsLeftOutOfTheCommand() {
        let command = Self.handoff(Self.choice(.clear, .same), model: "x'; rm -rf ~; '").shellCommand

        #expect(!command.contains("--model"))
    }

    @Test func compactForksCompactsAndThenResumesTheFork() {
        let command = Self.handoff(Self.choice(.compact, .sonnet, effort: .low, mode: .auto)).shellCommand

        #expect(
            command
                == "cd '/Users/sato/pets/cyclop' && \(Self.clean) -p --resume 'old-id' --fork-session --session-id 'new-id' '\(Self.shellInstruction)' > /dev/null"
                + " && \(Self.clean) --resume 'new-id' --model sonnet --effort low --permission-mode auto '\(Self.shellPlain)'")
    }

    @Test func compactWithTheSameModelAddsNoModel() {
        let command = Self.handoff(Self.choice(.compact, .same)).shellCommand

        #expect(command.hasSuffix("claude --resume 'new-id' --effort medium --permission-mode bypassPermissions '\(Self.shellPlain)'"))
    }

    @Test func keepWithSonnetForksTheSessionOntoSonnet() {
        let command = Self.handoff(Self.choice(.keep, .sonnet, mode: .default)).shellCommand

        #expect(
            command
                == "cd '/Users/sato/pets/cyclop' && \(Self.clean) --resume 'old-id' --fork-session --session-id 'new-id' --model sonnet --effort medium --permission-mode default '\(Self.shellPlain)'"
        )
    }

    @Test func aQuoteInTheFolderAndInTheTextIsEscapedForTheShell() {
        var handoff = Self.handoff(Self.choice(.clear, .sonnet))
        handoff.folder = "/Users/o'neil/my project"
        handoff.planFile = "plans/it's.md"

        let command = handoff.shellCommand

        #expect(command.hasPrefix(#"cd '/Users/o'\''neil/my project' && "#))
        #expect(command.contains(#"plan in plans/it'\''s.md."#))
        #expect(ClaudeHandoff.quoted("a'b") == #"'a'\''b'"#)
        #expect(ClaudeHandoff.quoted("") == "''")
    }

    /// В fish `\'` и `\\` внутри одинарных кавычек — escape-последовательности, в POSIX — нет:
    /// обратная косая закрывает кавычку, пишется отдельно и кавычка открывается снова.
    @Test func aBackslashLeavesTheQuotesSoFishAndPosixReadItTheSame() {
        #expect(ClaudeHandoff.quoted(#"a\b"#) == #"'a'\\'b'"#)
        #expect(ClaudeHandoff.quoted(#"/a\"#) == #"'/a'\\''"#)
        #expect(ClaudeHandoff.quoted(#"X\';evil;#"#) == #"'X'\\''\'';evil;#'"#)

        var handoff = Self.handoff(Self.choice(.clear, .sonnet))
        handoff.folder = #"/tmp/x\';touch pwned;#"#
        handoff.planFile = #"plans\it's.md"#
        let command = handoff.shellCommand

        #expect(command.hasPrefix(#"cd '/tmp/x'\\''\'';touch pwned;#' && "#))
        #expect(command.contains(#"plan in plans'\\'it'\''s.md."#))
    }

    // MARK: - Подготовка сессии для приложения и редактора

    @Test func clearPreparesANewSessionWithAReadyPrompt() {
        let steps = Self.handoff(Self.choice(.clear, .sonnet)).headlessSteps

        #expect(
            steps == [
                [
                    "-p", "--session-id", "new-id", "--model", "sonnet", "--effort", "medium", "--permission-mode", "default",
                    "--max-turns", "1", Self.ready,
                ]
            ])
    }

    /// Подготовка идёт без владельца: выбранный режим в ней не действует, ход один.
    @Test func everyPreparationTurnRunsInTheDefaultModeForOneTurnWhateverTheChoice() {
        for context in PlanChoice.Context.allCases {
            for mode in PlanChoice.Mode.allCases {
                for step in Self.handoff(Self.choice(context, .sonnet, mode: mode)).headlessSteps {
                    let isCompact = step.contains(Self.instruction)
                    #expect(step.contains("--max-turns") == !isCompact, "\(step)")
                    #expect(!step.contains("bypassPermissions") && !step.contains("acceptEdits") && !step.contains("auto"), "\(step)")
                    #expect(isCompact || step.firstIndex(of: "--permission-mode").map { step[$0 + 1] == "default" } == true, "\(step)")
                }
            }
        }
    }

    @Test func compactPreparesTwoStepsTheSecondOnTheTargetModel() {
        let steps = Self.handoff(Self.choice(.compact, .sonnet, effort: .xhigh, mode: .acceptEdits)).headlessSteps

        #expect(
            steps == [
                ["-p", "--resume", "old-id", "--fork-session", "--session-id", "new-id", Self.instruction],
                [
                    "-p", "--resume", "new-id", "--model", "sonnet", "--effort", "xhigh", "--permission-mode", "default",
                    "--max-turns", "1", Self.ready,
                ],
            ])
    }

    @Test func keepWithSonnetPreparesOneForkedStep() {
        let steps = Self.handoff(Self.choice(.keep, .sonnet)).headlessSteps

        #expect(
            steps == [
                [
                    "-p", "--resume", "old-id", "--fork-session", "--session-id", "new-id", "--model", "sonnet", "--effort", "medium",
                    "--permission-mode", "default", "--max-turns", "1", Self.ready,
                ]
            ])
    }

    // MARK: - Окружение и исполняемый файл

    @Test func theEnvironmentLosesWhatMakesItAChildOfAClaudeSession() {
        let scrubbed = ClaudeHandoff.scrubbedEnvironment([
            "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_AGENT_SDK_VERSION": "1",
            "CLAUDE_PID": "7", "CLAUDE_EFFORT": "high", "PATH": "/usr/bin", "HOME": "/Users/sato", "CLAUDE_CONFIG_DIR": "/c",
        ])

        #expect(scrubbed == ["PATH": "/usr/bin", "HOME": "/Users/sato", "CLAUDE_CONFIG_DIR": "/c"])
    }

    @Test func theSessionsOwnClaudeIsUsedAndElseTheFirstUsualPlace() {
        let existing: Set<String> = ["/usr/local/bin/claude", "/Users/sato/.local/bin/claude", "/Users/sato/.claude/local/claude"]
        let own = ClaudeHandoff.executable(
            processPath: "/Users/sato/.claude/local/claude", home: "/Users/sato", exists: existing.contains)
        let node = ClaudeHandoff.executable(processPath: "/opt/node/bin/node", home: "/Users/sato", exists: existing.contains)
        let none = ClaudeHandoff.executable(processPath: nil, home: "/Users/sato", exists: { _ in false })

        #expect(own?.path == "/Users/sato/.claude/local/claude")
        #expect(node?.path == "/usr/local/bin/claude")
        #expect(none == nil)
    }

    @Test func aFailedStepsReasonIsTheLastNonEmptyLineCutTo200Characters() {
        #expect(ClaudeHandoff.reason(ofStandardError: "warn\nError: no auth\n\n  \n") == "Error: no auth")
        #expect(ClaudeHandoff.reason(ofStandardError: "") == "")
        #expect(ClaudeHandoff.reason(ofStandardError: String(repeating: "я", count: 500)).count == 200)
    }

    // MARK: - Разрешён ли bypass

    @Test func bypassIsAllowedByAnyOfTheThreeFlagsInBothForms() {
        let allowed = [
            ["claude", "--allow-dangerously-skip-permissions"],
            ["claude", "--allow-dangerously-skip-permissions=true"],
            ["claude", "--dangerously-skip-permissions"],
            ["claude", "--dangerously-skip-permissions=true"],
            ["claude", "--permission-mode", "bypassPermissions"],
            ["claude", "--permission-mode=bypassPermissions", "-p"],
        ]
        for arguments in allowed { #expect(ClaudeHandoff.allowsBypass(arguments: arguments), "\(arguments)") }
    }

    @Test func bypassIsNotAllowedWithoutAFlagOrWithAnotherMode() {
        let refused = [
            [], ["claude"], ["claude", "--model", "sonnet"], ["claude", "--permission-mode", "plan"],
            ["claude", "--permission-mode=acceptEdits"], ["claude", "--permission-mode"],
            ["claude", "--allow-dangerously-skip-permissions=false"], ["claude", "--allow-dangerously-skip-permissionsX"],
        ]
        for arguments in refused { #expect(!ClaudeHandoff.allowsBypass(arguments: arguments), "\(arguments)") }
    }

    // MARK: - Модель из хвоста расшифровки

    private static func record(_ type: String, model: String? = nil, sidechain: Bool = false) -> String {
        let message = model.map { #","message":{"role":"assistant","model":"\#($0)","content":[]}"# } ?? ""
        return #"{"type":"\#(type)","isSidechain":\#(sidechain)\#(message)}"#
    }

    private static func tail(_ lines: [String]) -> Data { Data(lines.joined(separator: "\n").utf8) }

    @Test func theLastAssistantRecordWins() {
        let data = Self.tail([
            Self.record("assistant", model: "claude-opus-5-5"), Self.record("user"),
            Self.record("assistant", model: "claude-sonnet-5-5"), Self.record("user"),
        ])

        #expect(ClaudeHandoff.lastModel(inTail: data) == "claude-sonnet-5-5")
    }

    @Test func aSidechainRecordIsSkipped() {
        let data = Self.tail([
            Self.record("assistant", model: "claude-opus-5-5"), Self.record("assistant", model: "claude-haiku-5-5", sidechain: true),
        ])

        #expect(ClaudeHandoff.lastModel(inTail: data) == "claude-opus-5-5")
    }

    @Test func aSyntheticRecordIsSkipped() {
        let data = Self.tail([Self.record("assistant", model: "claude-opus-5-5"), Self.record("assistant", model: "<synthetic>")])

        #expect(ClaudeHandoff.lastModel(inTail: data) == "claude-opus-5-5")
    }

    @Test func aFirstLineCutByTheTailIsSkipped() {
        let cut = #"ssistant","message":{"model":"claude-haiku-5-5"}}"#
        let data = Self.tail([cut, Self.record("user")])

        #expect(ClaudeHandoff.lastModel(inTail: data) == nil)
        // Первая строка хвоста, который обрезан, отбрасывается, даже если читается целой записью.
        let whole = Self.tail([Self.record("assistant", model: "claude-haiku-5-5"), Self.record("user")])
        #expect(ClaudeHandoff.lastModel(inTail: whole, cut: true) == nil)
        #expect(ClaudeHandoff.lastModel(inTail: whole) == "claude-haiku-5-5")
    }

    @Test func noAssistantRecordMeansNoModel() {
        #expect(ClaudeHandoff.lastModel(inTail: Self.tail([Self.record("user"), Self.record("attachment")])) == nil)
        #expect(ClaudeHandoff.lastModel(inTail: Data()) == nil)
        #expect(ClaudeHandoff.lastModel(inTail: Data("not json\n{broken".utf8)) == nil)
    }

    @Test func theFileReaderTakesTheModelFromTheEndOfALongFile() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cyclop-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("t.jsonl")
        let filler = Self.record("user") + String(repeating: " ", count: 4000)
        let lines = [Self.record("assistant", model: "claude-opus-5-5")] + Array(repeating: filler, count: 100)
            + [Self.record("assistant", model: "claude-sonnet-5-5"), Self.record("user")]
        try Self.tail(lines).write(to: file)

        #expect(ClaudeHandoff.lastModel(ofFile: file, tail: 16 * 1024) == "claude-sonnet-5-5")
        #expect(ClaudeHandoff.lastModel(ofFile: folder.appendingPathComponent("none.jsonl")) == nil)
        // Все записи до хвоста — не ассистент: из хвоста модели нет.
        try Self.tail([Self.record("assistant", model: "claude-opus-5-5")] + Array(repeating: filler, count: 100)).write(to: file)
        #expect(ClaudeHandoff.lastModel(ofFile: file, tail: 16 * 1024) == nil)
    }

    @Test func theFileReaderLeavesAnythingButARegularFileAlone() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cyclop-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fifo = folder.appendingPathComponent("t.fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)

        // Ни чтение FIFO, ни /dev/zero не должны зависнуть.
        #expect(ClaudeHandoff.lastModel(ofFile: fifo) == nil)
        #expect(ClaudeHandoff.lastModel(ofFile: URL(fileURLWithPath: "/dev/zero")) == nil)
        #expect(ClaudeHandoff.lastModel(ofFile: folder) == nil)
    }

    // MARK: - Расшифровка по умолчанию

    @Test func theTranscriptPathReplacesEveryNonAlphanumericCharacterWithADash() {
        let path = ClaudeHandoff.transcriptPath(
            folder: "/Users/sato/.cache/my project_1", sessionID: "abc-123", home: "/Users/sato")

        #expect(path == "/Users/sato/.claude/projects/-Users-sato--cache-my-project-1/abc-123.jsonl")
        #expect(ClaudeHandoff.transcriptPath(folder: "/я/b", sessionID: "s", home: "/h") == "/h/.claude/projects/---b/s.jsonl")
    }

    // MARK: - Командная строка процесса

    @Test func theKernelGivesTheArgumentsOfAProcess() {
        // Ровно argv этого процесса: не меньше, не больше, без окружения.
        #expect(ProcessTable.arguments(of: Int(getpid())) == CommandLine.arguments)
        #expect(ProcessTable.arguments(of: 0x7fff_fff0) == nil)
    }
}
