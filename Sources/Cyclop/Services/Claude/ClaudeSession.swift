import Foundation

/// One running Claude Code process, as the tab shows it.
struct ClaudeSession: Identifiable, Equatable {
    enum State: Equatable { case working, waiting, idle }
    enum Place: Equatable { case app, editor, terminal }

    let pid: Int
    let sessionID: String?
    /// The Claude app's own id for the session; only sessions started there have one.
    let hostSessionID: String?
    let name: String
    let folder: String
    let place: Place
    let state: State
    /// When the state last changed.
    let since: Date
    /// What the session file says is asked (`input needed`, `permission prompt`).
    let waitingFor: String?

    var id: Int { pid }
}

/// `~/.claude/sessions/<pid>.json`. An internal format of Claude Code, so every
/// field is optional and a field of the wrong type reads as absent.
struct ClaudeSessionFile: Decodable {
    var pid: Int?
    var procStart: String?
    var sessionId: String?
    var cwd: String?
    var name: String?
    var entrypoint: String?
    var kind: String?
    var startedAt: Double?
    var updatedAt: Double?
    var status: String?
    var statusUpdatedAt: Double?
    var waitingFor: String?
    var hostSessionId: String?

    private enum Key: String, CodingKey {
        case pid, procStart, sessionId, cwd, name, entrypoint, kind, startedAt, updatedAt
        case status, statusUpdatedAt, waitingFor, hostSessionId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func field<T: Decodable>(_ key: Key) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
        pid = field(.pid)
        procStart = field(.procStart)
        sessionId = field(.sessionId)
        cwd = field(.cwd)
        name = field(.name)
        entrypoint = field(.entrypoint)
        kind = field(.kind)
        startedAt = field(.startedAt)
        updatedAt = field(.updatedAt)
        status = field(.status)
        statusUpdatedAt = field(.statusUpdatedAt)
        waitingFor = field(.waitingFor)
        hostSessionId = field(.hostSessionId)
    }

    /// Nil for what is not a session a person drives: a headless run, a file
    /// with no state yet, or one without a process id.
    func session(fallbackPid: Int?, now: Date) -> ClaudeSession? {
        guard kind == "interactive", let status, let pid = pid ?? fallbackPid else { return nil }
        let folder = cwd ?? ""
        let since = (statusUpdatedAt ?? updatedAt ?? startedAt).map { Date(timeIntervalSince1970: $0 / 1000) } ?? now
        return ClaudeSession(
            pid: pid,
            sessionID: sessionId,
            hostSessionID: hostSessionId,
            name: Self.title(name, folder: folder),
            folder: folder,
            place: Self.place(entrypoint),
            // A state this version does not know is shown as waiting: a new kind of wait must not hide.
            state: status == "busy" ? .working : status == "idle" ? .idle : .waiting,
            since: since,
            waitingFor: waitingFor
        )
    }

    private static func title(_ name: String?, folder: String) -> String {
        if let name, !name.isEmpty { return name }
        let last = (folder as NSString).lastPathComponent
        return last.isEmpty ? "Claude" : last
    }

    private static func place(_ entrypoint: String?) -> ClaudeSession.Place {
        switch entrypoint {
        case "claude-desktop": return .app
        case "claude-vscode": return .editor
        default: return .terminal
        }
    }
}
