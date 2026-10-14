import Foundation

/// One question of an `AskUserQuestion` request.
struct ClaudeQuestion: Equatable {
    struct Option: Equatable {
        let label: String
        let description: String
    }

    let text: String
    let header: String?
    let options: [Option]
    /// Several options may be chosen: not answered in the panel.
    let multiSelect: Bool

    init?(_ tree: JSONTree) {
        guard let text = tree["question"]?.text else { return nil }
        self.text = text
        header = tree["header"]?.text
        options = (tree["options"]?.items ?? []).compactMap { option in
            option["label"]?.text.map { Option(label: $0, description: option["description"]?.text ?? "") }
        }
        multiSelect = tree["multiSelect"] == .scalar("true")
    }
}

/// What a waiting session asks, as the `PermissionRequest` hook delivered it. Lives in memory only.
struct ClaudeRequest: Identifiable, Equatable {
    /// By the tool: a question, a plan, or anything else.
    enum Kind: Equatable { case permission, question, plan }

    let id = UUID()
    /// The session's id as the hook gave it, and the listed session's process it matched.
    let sessionID: String
    let pid: Int
    let toolName: String
    let kind: Kind
    let arrived: Date
    /// `tool_input` as received: a reply that repeats it repeats this.
    let input: JSONTree
    /// Empty unless this is a question; empty too when the tool's input is not the shape known.
    let questions: [ClaudeQuestion]
    /// The answers given so far in the panel, one per question from the first; the next question is the one after.
    var answers: [String] = []
    /// The `addRules` entries of `permission_suggestions` as received: what Always Allow sends back.
    /// The session-only suggestions (`setMode`, `addDirectories`) are left out on purpose.
    let rules: [JSONTree]
    /// The rules in one line, for the button; nil when there is none or it cannot be said in one line.
    let rule: String?
    /// The plan's first heading (its first line when it has none), and the lines after it.
    let planTitle: String
    let planBeginning: String
    /// The payload's session facts, nil when absent or empty: the folder, the transcript file, the effort
    /// level, and the subagent's id when a subagent asks.
    let cwd: String?
    let transcriptPath: String?
    let effort: String?
    let agentID: String?
    /// `tool_input.planFilePath` of a plan; nil for any other request.
    let planFilePath: String?

    /// Nil for what is not a request of a listed session: the body is not a hook's input,
    /// or `pidOf` knows no session with that id.
    init?(body: Data, arrived: Date, pidOf: (String) -> Int?) {
        guard let text = String(data: body, encoding: .utf8), let tree = JSONTree(parsing: text),
            let sessionID = tree["session_id"]?.text, let toolName = tree["tool_name"]?.text,
            let pid = pidOf(sessionID)
        else { return nil }
        self.sessionID = sessionID
        self.pid = pid
        self.toolName = toolName
        self.arrived = arrived
        input = tree["tool_input"] ?? .object([])
        switch toolName {
        case "AskUserQuestion": kind = .question
        case "ExitPlanMode": kind = .plan
        default: kind = .permission
        }
        questions = kind == .question ? (input["questions"]?.items ?? []).compactMap(ClaudeQuestion.init) : []
        rules = kind == .permission
            ? (tree["permission_suggestions"]?.items ?? []).filter { $0["type"]?.text == "addRules" } : []
        rule = Self.oneLine(rules)
        cwd = Self.present(tree["cwd"]?.text)
        transcriptPath = Self.present(tree["transcript_path"]?.text)
        effort = Self.present(tree["effort"]?["level"]?.text)
        agentID = Self.present(tree["agent_id"]?.text)
        planFilePath = kind == .plan ? Self.present(input["planFilePath"]?.text) : nil
        (planTitle, planBeginning) = kind == .plan ? Self.excerpt(ofPlan: input["plan"]?.text ?? "") : ("", "")
    }

    private static func present(_ text: String?) -> String? { text?.isEmpty == false ? text : nil }

    /// What the tool is asked to touch: the command, the file, the address; else the input itself.
    var detail: String {
        for key in ["command", "file_path", "notebook_path", "path", "url", "pattern", "query"] {
            if let text = input[key]?.text { return Self.shortened(text, to: 400) }
        }
        return Self.shortened(input.compact, to: 400)
    }

    /// `text` cut to `limit` characters, so a command or a plan of any length stays cheap to draw.
    static func shortened(_ text: String, to limit: Int) -> String {
        text.count > limit ? text.prefix(limit).trimmingCharacters(in: .whitespacesAndNewlines) + "…" : text
    }

    /// `Bash(touch x)`; several rules joined by commas. Nil without a rule, and for one that is not one line.
    private static func oneLine(_ entries: [JSONTree]) -> String? {
        var lines: [String] = []
        for rule in entries.flatMap({ $0["rules"]?.items ?? [] }) {
            guard let tool = rule["toolName"]?.text else { return nil }
            lines.append(rule["ruleContent"]?.text.map { "\(tool)(\($0))" } ?? tool)
        }
        guard !lines.isEmpty, !lines.contains(where: { $0.contains("\n") }) else { return nil }
        return shortened(lines.joined(separator: ", "), to: 120)
    }

    private static func excerpt(ofPlan plan: String) -> (title: String, beginning: String) {
        var lines = plan.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let index = lines.firstIndex { $0.hasPrefix("#") } ?? 0
        guard lines.indices.contains(index) else { return ("", "") }
        let title = lines.remove(at: index).drop { $0 == "#" || $0 == " " }
        return (shortened(String(title), to: 120), shortened(lines.prefix(30).joined(separator: "\n"), to: 600))
    }

    /// The question the owner is on, if this request is answered question by question in the panel.
    var current: ClaudeQuestion? {
        guard isAnsweredInPanel, answers.count < questions.count else { return nil }
        return questions[answers.count]
    }

    /// A question whose every part can be answered by one option or own text.
    var isAnsweredInPanel: Bool {
        kind == .question && !questions.isEmpty && !questions.contains { $0.multiSelect || $0.options.isEmpty }
    }
}

/// What a request is answered with: the output the hook prints.
enum ClaudeReply {
    /// Every question of the request answered, each with a label or the owner's own text.
    case answers(of: ClaudeRequest)
    /// Let the command, the edit or the request happen this once.
    case allow
    /// Allow, and remember the rule Claude itself offered: only the rule entries of the suggestions.
    case alwaysAllow(of: ClaudeRequest)
    /// Refuse; Claude receives the text as the tool's error.
    case deny(message: String)
    /// Approve a plan in its session, in the given mode: only a reply that repeats the tool's input is taken,
    /// a bare allow is ignored.
    case approve(plan: ClaudeRequest, mode: PlanChoice.Mode)
    /// Refuse and end the turn at once, with no retry; the session stays where it was.
    case interrupt(message: String)

    var data: Data {
        switch self {
        case .allow:
            return Self.decision([.init("behavior", .string("allow"))])
        case .alwaysAllow(let request):
            return Self.decision([
                .init("behavior", .string("allow")), .init("updatedPermissions", .array(request.rules)),
            ])
        case .deny(let message):
            return Self.decision([.init("behavior", .string("deny")), .init("message", .string(message))])
        case .approve(let plan, let mode):
            // The destination must be the session: any other writes `permissions.defaultMode` into a settings file.
            let setMode = JSONTree.object([
                .init("type", .string("setMode")), .init("mode", .string(mode.rawValue)),
                .init("destination", .string("session")),
            ])
            return Self.decision([
                .init("behavior", .string("allow")), .init("updatedInput", plan.input),
                .init("updatedPermissions", .array([setMode])),
            ])
        case .interrupt(let message):
            return Self.decision([
                .init("behavior", .string("deny")), .init("message", .string(message)),
                .init("interrupt", .scalar("true")),
            ])
        case .answers(let request):
            let given = zip(request.questions, request.answers).map { JSONTree.Member($0.text, .string($1)) }
            var input = request.input.members ?? []
            input.removeAll { $0.name == "answers" }
            input.append(.init("answers", .object(given)))
            return Self.allow(updatedInput: .object(input))
        }
    }

    private static func allow(updatedInput: JSONTree) -> Data {
        decision([.init("behavior", .string("allow")), .init("updatedInput", updatedInput)])
    }

    /// `{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": …}}`.
    private static func decision(_ members: [JSONTree.Member]) -> Data {
        let output = JSONTree.object([
            .init(
                "hookSpecificOutput",
                .object([
                    .init("hookEventName", .string("PermissionRequest")),
                    .init("decision", .object(members)),
                ]))
        ])
        return Data(output.compact.utf8)
    }
}
