import Foundation

/// How an approved plan goes on: what the plan card lets the owner choose. In memory with the request.
struct PlanChoice: Equatable, Sendable {
    enum Context: String, CaseIterable, Sendable { case keep, compact, clear }
    enum ModelChoice: String, CaseIterable, Sendable { case same, sonnet }
    enum Effort: String, CaseIterable, Sendable { case low, medium, high, xhigh, max }
    /// The raw values are Claude Code's own mode names (`--permission-mode`, `setMode`).
    enum Mode: String, CaseIterable, Sendable { case bypassPermissions, auto, acceptEdits, `default` }

    var context: Context = .clear
    var model: ModelChoice = .sonnet
    var effort: Effort = .medium
    var mode: Mode = .bypassPermissions

    init() {}

    init(context: Context, model: ModelChoice, effort: Effort, mode: Mode) {
        self.context = context
        self.model = model
        self.effort = effort
        self.mode = mode
    }

    /// From the Settings defaults; a value this version does not know reads as the default.
    init(_ config: ConfigStore.PlanApproval) {
        let d = PlanChoice()
        context = Context(rawValue: config.context) ?? d.context
        model = ModelChoice(rawValue: config.model) ?? d.model
        effort = Effort(rawValue: config.effort) ?? d.effort
        mode = Mode(rawValue: config.mode) ?? d.mode
    }

    var config: ConfigStore.PlanApproval {
        var config = ConfigStore.PlanApproval()
        config.context = context.rawValue
        config.model = model.rawValue
        config.effort = effort.rawValue
        config.mode = mode.rawValue
        return config
    }

    /// In place when nothing about the context or the model has to change; else a new session.
    func route(sessionModel: String?) -> PlanRoute {
        guard context == .keep else { return .handoff }
        return model == .same || ClaudeHandoff.isSonnet(sessionModel) ? .inPlace : .handoff
    }
}

enum PlanRoute: Equatable, Sendable {
    /// Approve through the hook reply, with a mode.
    case inPlace
    /// Stop the old turn and start a new session.
    case handoff
}

/// Why a plan cannot be handed off from this request: the card shows "Only in this session here".
enum HandoffUnavailable: Equatable, Sendable {
    case noPlanFile, subagent, noFolder
    /// The session runs in a terminal other than Terminal and iTerm.
    case unknownTerminal
    /// The session runs in an editor with no link scheme.
    case noURLScheme
    /// The Claude app or editor session has no `claude` to prepare the new session with.
    case noExecutable
    /// A value that reaches the terminal command holds a control character, which the line editor would act on.
    case controlCharacters
}

/// A hand-off made of the plan's facts and the choice: the texts and commands, all pure.
struct ClaudeHandoff: Equatable {
    var choice: PlanChoice
    /// The session's current model id when known.
    var sessionModel: String?
    var folder: String
    var sessionID: String
    var newSessionID: String
    var planFile: String
    var transcript: String

    /// The deny's text; Claude does not show it to the model (a live check), the owner never sees it.
    static let interruptMessage = "Approved in Cyclop; the plan goes on in a new session."

    static let terminalBundleID = "com.apple.Terminal"
    static let iTermBundleID = "com.googlecode.iterm2"

    // MARK: - Availability

    /// `typed` are the other values a terminal command would carry (ids, transcript path); `hasExecutable`
    /// matters to the app and the editor only.
    static func unavailable(
        planFile: String?, agentID: String?, folder: String, place: ClaudeSession.Place,
        hostBundleID: String?, hostURLScheme: String?, typed: [String] = [], hasExecutable: Bool = true
    ) -> HandoffUnavailable? {
        if planFile?.isEmpty ?? true { return .noPlanFile }
        if agentID?.isEmpty == false { return .subagent }
        if folder.isEmpty { return .noFolder }
        switch place {
        case .terminal:
            guard hostBundleID == terminalBundleID || hostBundleID == iTermBundleID else { return .unknownTerminal }
            return hasControlCharacter([planFile ?? "", folder] + typed) ? .controlCharacters : nil
        case .editor:
            guard hostURLScheme?.isEmpty == false else { return .noURLScheme }
            return hasExecutable ? nil : .noExecutable
        case .app:
            return hasExecutable ? nil : .noExecutable
        }
    }

    /// A scalar below 0x20 or 0x7f: the tty and the line editor act on it even inside quotes.
    static func hasControlCharacter(_ values: [String]) -> Bool {
        values.contains { $0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } }
    }

    static func isSonnet(_ model: String?) -> Bool {
        model?.lowercased().contains("sonnet") ?? false
    }

    // MARK: - Texts

    /// What the new session starts from. A prepared one only names the files for later and is told to do nothing.
    func prompt(prepared: Bool) -> String {
        guard prepared else {
            return "Implement the plan in \(planFile). If you need specific details from the planning "
                + "(exact code, error messages, findings), read the planning session's transcript: \(transcript)."
        }
        return "The plan to implement when the owner says go is in \(planFile). If you need specific details from the "
            + "planning (exact code, error messages, findings), read the planning session's transcript then: \(transcript)."
            + "\n\nDo not use any tool and do not change anything now: reply only with the word Ready. "
            + "The owner will start the work in Claude."
    }

    var compactInstruction: String {
        "/compact Keep what the approved plan in \(planFile) needs: decisions, findings, file paths and the owner's remarks."
    }

    // MARK: - Commands

    /// `--model` for the new session: Sonnet by choice; "same" with clear names the old model when known,
    /// and with compact or keep the resume restores it.
    private var modelArgument: String? {
        switch choice.model {
        case .sonnet: return "sonnet"
        case .same: return choice.context == .clear ? Self.safeModelID(sessionModel) : nil
        }
    }

    /// A model id comes from a file: only a plain id may reach a command line.
    private static func safeModelID(_ id: String?) -> String? {
        guard let id, id.wholeMatch(of: /[A-Za-z0-9._-]{1,100}/) != nil else { return nil }
        return id
    }

    private var options: [String] {
        (modelArgument.map { ["--model", $0] } ?? []) + ["--effort", choice.effort.rawValue, "--permission-mode", choice.mode.rawValue]
    }

    /// A prepared session never runs in the chosen mode: one turn, and a tool call is refused, not run unattended.
    private var preparationOptions: [String] {
        (modelArgument.map { ["--model", $0] } ?? [])
            + ["--effort", choice.effort.rawValue, "--permission-mode", "default", "--max-turns", "1"]
    }

    /// `'` becomes `'\''` and `\` becomes `'\\'`: the same in POSIX shells and fish, where a backslash
    /// is an escape even inside single quotes.
    static func quoted(_ text: String) -> String {
        var out = "'"
        for scalar in text.unicodeScalars {
            switch scalar {
            case "'": out += "'\\''"
            case "\\": out += "'\\\\'"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "'"
    }

    private static let clean = "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_CHILD_SESSION claude"

    /// The one shell command a terminal runs; the prompt is the plain one.
    var shellCommand: String {
        let q = Self.quoted
        let tail = (options + [q(prompt(prepared: false))]).joined(separator: " ")
        let start: String
        switch choice.context {
        case .clear:
            start = "\(Self.clean) \(tail)"
        case .compact:
            start = "\(Self.clean) -p --resume \(q(sessionID)) --fork-session --session-id \(q(newSessionID)) "
                + "\(q(compactInstruction)) > /dev/null && \(Self.clean) --resume \(q(newSessionID)) \(tail)"
        case .keep:
            start = "\(Self.clean) --resume \(q(sessionID)) --fork-session --session-id \(q(newSessionID)) \(tail)"
        }
        return "cd \(q(folder)) && \(start)"
    }

    /// The `claude -p` runs that prepare a session for the app or the editor, one argument list each.
    var headlessSteps: [[String]] {
        let text = prompt(prepared: true)
        let options = preparationOptions
        switch choice.context {
        case .clear:
            return [["-p", "--session-id", newSessionID] + options + [text]]
        case .compact:
            return [
                ["-p", "--resume", sessionID, "--fork-session", "--session-id", newSessionID, compactInstruction],
                ["-p", "--resume", newSessionID] + options + [text],
            ]
        case .keep:
            return [["-p", "--resume", sessionID, "--fork-session", "--session-id", newSessionID] + options + [text]]
        }
    }

    // MARK: - Environment and executable

    /// The environment of a `claude` Cyclop starts: nothing that makes it a child of a Claude session.
    static func scrubbedEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { name, _ in
            !(name == "CLAUDECODE" || name == "CLAUDE_PID" || name == "CLAUDE_EFFORT"
                || name.hasPrefix("CLAUDE_CODE_") || name.hasPrefix("CLAUDE_AGENT_SDK_"))
        }
    }

    /// The session process's own `claude` when its file is named so, else the first usual place that has one.
    static func executable(processPath: String?, home: String, exists: (String) -> Bool) -> URL? {
        if let processPath, URL(fileURLWithPath: processPath).lastPathComponent == "claude", exists(processPath) {
            return URL(fileURLWithPath: processPath)
        }
        let usual = [
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.local/bin/claude", home + "/.claude/local/claude",
        ]
        return usual.first(where: exists).map { URL(fileURLWithPath: $0) }
    }

    /// The reason a failed step gives: the last non-empty line of its standard error, cut to 200 characters.
    static func reason(ofStandardError text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        return String((line ?? "").prefix(200))
    }

    // MARK: - Session facts

    /// Whether a session started with these arguments can be switched into bypass permissions.
    static func allowsBypass(arguments: [String]) -> Bool {
        let flags = ["--allow-dangerously-skip-permissions", "--dangerously-skip-permissions"]
        for (index, argument) in arguments.enumerated() {
            for flag in flags where argument == flag || (argument.hasPrefix(flag + "=") && !argument.hasSuffix("=false")) {
                return true
            }
            if argument == "--permission-mode", arguments.indices.contains(index + 1),
                arguments[index + 1] == "bypassPermissions"
            {
                return true
            }
            if argument == "--permission-mode=bypassPermissions" { return true }
        }
        return false
    }

    /// `~/.claude/projects/<folder with every non-alphanumeric character as ->/<session>.jsonl`:
    /// where the transcript is when the payload names none.
    static func transcriptPath(folder: String, sessionID: String, home: String) -> String {
        // Per UTF-16 unit, as Claude Code's own JavaScript does.
        let slug = String(folder.utf16.map { unit -> Character in
            let plain = (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit)
            return plain ? Character(Unicode.Scalar(UInt8(unit))) : "-"
        })
        return "\(home)/.claude/projects/\(slug)/\(sessionID).jsonl"
    }

    /// `message.model` of the last main-thread assistant record in the tail of a transcript. A line cut by the
    /// tail does not parse, so it is skipped by itself; `cut` drops the first line without trying.
    static func lastModel(inTail data: Data, cut: Bool = false) -> String? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if cut, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            let text = String(decoding: line, as: UTF8.self)
            guard text.contains("\"assistant\""), let record = JSONTree(parsing: text),
                record["type"]?.text == "assistant", record["isSidechain"] != .scalar("true"),
                let model = record["message"]?["model"]?.text,
                // "<synthetic>" stands for a message Claude Code wrote itself.
                !model.isEmpty, !model.hasPrefix("<")
            else { continue }
            return model
        }
        return nil
    }

    /// The same over the last 256 KB of a regular file; nil for anything else (a FIFO or a device would hang the read).
    static func lastModel(ofFile url: URL, tail: Int = 256 * 1024) -> String? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            return nil
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let size = UInt64(max(info.st_size, 0))
        let start = size > UInt64(tail) ? size - UInt64(tail) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.read(upToCount: tail) else { return nil }
        return lastModel(inTail: data, cut: start > 0)
    }
}

/// What the owner sees of one hand-off. In memory only.
struct ClaudeHandoffStatus: Identifiable, Equatable {
    enum Phase: Equatable {
        case preparing
        case opened
        case failed(ClaudeHandoffFailure)
    }

    let id = UUID()
    /// The old session's name, for the row.
    let sessionName: String
    /// Where the plan goes on: the words of the row follow it.
    let place: ClaudeSession.Place
    var phase: Phase
    /// The shell command of a terminal hand-off, for Copy Command.
    let command: String?
}

/// Why a hand-off failed; the pane words it.
enum ClaudeHandoffFailure: Equatable {
    /// The terminal script was refused (Automation, error -1743).
    case automationDenied
    /// The terminal script failed for another reason.
    case terminalFailed
    case noExecutable
    /// The session was made but there is no link to open it with.
    case noLink
    case timedOut
    /// A step exited non-zero: the last line of its standard error.
    case step(String)
    /// A step exited non-zero with nothing on its standard error.
    case exitStatus(Int32)
}
