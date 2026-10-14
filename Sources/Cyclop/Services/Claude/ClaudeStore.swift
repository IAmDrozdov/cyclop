import Foundation

/// The Claude tab's sessions, read from Claude Code's own session files, and the requests they send through the connection.
@MainActor
final class ClaudeStore: ObservableObject {
    /// How long after finishing an idle session stays in the list; an older one is not listed at all.
    static let idleWindow: TimeInterval = 24 * 3600
    /// The slow timer: covers a file rewritten in place and a process killed without a trace.
    private static let pollInterval: TimeInterval = 5

    /// Waiting (longest wait first), working (latest change first), idle within the last day (latest first).
    @Published private(set) var sessions: [ClaudeSession] = []

    /// Requests waiting for an answer, oldest first. In memory only.
    @Published private(set) var requests: [ClaudeRequest] = [] {
        didSet { if requests.isEmpty, !oldValue.isEmpty { onRequestsGone?() } }
    }
    /// Whether a request has arrived that the owner has not seen: raised by an arrival, cleared by
    /// `markSeen()` and when the last unseen request goes away. The view model reads it to pick the tab.
    @Published private(set) var hasUnseenRequest = false {
        didSet { if hasUnseenRequest != oldValue { onUnseenChange?() } }
    }
    /// Raised after `hasUnseenRequest` changed.
    var onUnseenChange: (() -> Void)?
    /// Raised for every request that joins the list, whether or not the flag moved.
    var onArrival: (() -> Void)?
    /// Raised when the last request leaves the list: answered, hung up, withdrawn or closed.
    var onRequestsGone: (() -> Void)?
    /// Whether Cyclop's entry is in Claude's settings, as last read.
    @Published private(set) var connection = ClaudeSettingsEdit.State.notConnected
    /// Why the last press of Connect or Disconnect changed nothing, when the file was readable.
    @Published private(set) var connectionFailure: ClaudeSettingsFile.Failure?
    /// The socket could not be opened, so the tab works as a list.
    @Published private(set) var listenFailed = false

    var waitingCount: Int { sessions.filter { $0.state == .waiting }.count }

    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    private let folder: URL
    private let isAlive: (Int, String?) -> Bool
    private let opener: ClaudeOpening
    private let settings: ClaudeSettingsFile
    private let command: String
    private let listener: any ClaudeListening
    private let now: () -> Date
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var running = false
    private var listening = false
    /// How many settings readings in a row found the file unreadable.
    private var unreadableReadings = 0
    /// Requests whose session was missing from the last reload: withdrawn if it is missing from the next too.
    private var missing: Set<UUID> = []
    /// The relay of each request in `requests`.
    private var connections: [UUID: any ClaudeReplying] = [:]
    /// The requests of `requests` the owner has not seen; `hasUnseenRequest` is whether any is left.
    private var unseen: Set<UUID> = []
    /// The text typed into a request's field (a question's own answer, a plan's remarks); a request
    /// has an entry exactly while its field is open. Not published, on purpose: a change per
    /// keystroke would be forwarded to the whole panel and rebuild the field, which drops its focus.
    private var drafts: [UUID: String] = [:]
    /// Whether a field of a request is on screen; read when a click asks whether to take the keyboard.
    /// Cleared by the store when no draft is left, so a field that goes with its request cannot leave it set.
    private(set) var fieldShown = false

    init(
        folder: URL = ClaudeStore.defaultFolder,
        isAlive: @escaping (Int, String?) -> Bool = ProcessTable.isAlive(pid:procStart:),
        opener: ClaudeOpening = SystemClaudeOpener(),
        settings: ClaudeSettingsFile = .standard,
        command: String = ClaudeSettingsEdit.command(
            forExecutable: Bundle.main.executablePath ?? CommandLine.arguments[0]),
        listener: any ClaudeListening = SocketListening(),
        now: @escaping () -> Date = Date.init
    ) {
        self.folder = folder
        self.isAlive = isAlive
        self.opener = opener
        self.settings = settings
        self.command = command
        self.listener = listener
        self.now = now
    }

    // MARK: - Tab background

    func beginBackground() {
        running = true
        reload()
        readConnection()
        watch()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The folder may appear after the tab does, with Claude Code's first run.
                if self.watcher == nil { self.watch() }
                self.reload()
                self.readConnection()
            }
        }
    }

    func endBackground() {
        running = false
        unreadableReadings = 0
        updateListening()
        timer?.invalidate()
        timer = nil
        watcher?.cancel()
        watcher = nil
        sessions = []
    }

    private func watch() {
        guard watcher == nil else { return }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        // The main queue on purpose: see "Callbacks from system frameworks" in docs/architecture.md.
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.reload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    // MARK: - Reading

    func reload() {
        let moment = now()
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let found = entries.filter { $0.pathExtension == "json" }.compactMap { session(at: $0, now: moment) }

        let waiting = found.filter { $0.state == .waiting }.sorted { $0.since < $1.since }
        let working = found.filter { $0.state == .working }.sorted { $0.since > $1.since }
        let idle = found.filter { $0.state == .idle }.sorted { $0.since > $1.since }
        let recent = idle.filter { moment.timeIntervalSince($0.since) <= Self.idleWindow }

        let listed = waiting + working + recent
        // Published only when something shows differently, so a quiet poll repaints nothing.
        if listed != sessions { sessions = listed }
        withdrawOver(found)
    }

    // MARK: - Connection

    /// Reads the settings file again, for Settings coming into view.
    func refreshConnection() {
        connectionFailure = nil
        readConnection()
    }

    /// Writes Cyclop's entry (a copy of the file first); a file that cannot be read is left as it is.
    func connect() {
        change { try ClaudeSettingsEdit.connecting($0, command: command) }
    }

    /// Removes Cyclop's entry the same way.
    func disconnect() {
        change { try ClaudeSettingsEdit.disconnecting($0) }
    }

    private func change(_ edit: (String?) throws -> String) {
        connectionFailure = nil
        do {
            try settings.change(edit)
        } catch {
            connectionFailure = error as? ClaudeSettingsFile.Failure ?? .notChanged
        }
        readConnection()
    }

    private func readConnection() {
        let state: ClaudeSettingsEdit.State
        do {
            state = ClaudeSettingsEdit.state(of: try settings.read(), command: command)
        } catch {
            state = .unreadable
        }
        unreadableReadings = state == .unreadable ? unreadableReadings + 1 : 0
        // A file caught half-written or mid-edit: the first such reading changes nothing, because
        // closing the relays is final (the hooks have ended).
        if state == .unreadable, connection == .connected, unreadableReadings < 2 { return }
        if state != connection { connection = state }
        updateListening()
    }

    /// The socket is open exactly while the tab is on a rail and the entry names this executable.
    private func updateListening() {
        let should = running && connection == .connected
        guard should != listening else { return }
        if should {
            do {
                try listener.start { [weak self] data, relay in self?.receive(data, from: relay) }
                listening = true
                if listenFailed { listenFailed = false }
            } catch {
                if !listenFailed { listenFailed = true }
            }
        } else {
            listener.stop()
            closeRequests()
            listening = false
            if listenFailed { listenFailed = false }
        }
    }

    // MARK: - Requests

    /// A request from a relay. One of a listed session is queued; anything else is closed
    /// without an answer and Claude asks as usual.
    func receive(_ body: Data, from relay: any ClaudeReplying) {
        // The socket closed while this request was on its way to the main queue.
        guard listening else {
            relay.close()
            return
        }
        reload()
        let known = sessions
        guard let request = ClaudeRequest(
            body: body, arrived: now(), pidOf: { id in known.first { $0.sessionID == id }?.pid })
        else {
            relay.close()
            return
        }
        connections[request.id] = relay
        requests.append(request)
        let id = request.id
        unseen.insert(id)
        hasUnseenRequest = true
        relay.onHangup { [weak self] in MainActor.assumeIsolated { self?.drop(id) } }
        onArrival?()
    }

    /// Answers the question the request is on; after the last one, sends all the answers together.
    /// An empty answer is no answer.
    func answer(_ id: UUID, with answer: String) {
        guard let index = requests.firstIndex(where: { $0.id == id }), requests[index].current != nil,
            !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        discardDraft(id)
        requests[index].answers.append(answer)
        let request = requests[index]
        if request.answers.count == request.questions.count { send(.answers(of: request), for: id) }
    }

    /// Back to the previous question of the request, to answer it again.
    func goBack(_ id: UUID) {
        guard let index = requests.firstIndex(where: { $0.id == id }), !requests[index].answers.isEmpty else { return }
        discardDraft(id)
        requests[index].answers.removeLast()
    }

    /// Allows a permission once.
    func allow(_ id: UUID) {
        guard permission(id) != nil else { return }
        send(.allow, for: id)
    }

    /// Allows it and remembers the rule Claude offered; only when the request carries one.
    func alwaysAllow(_ id: UUID) {
        guard let request = permission(id), request.rule != nil else { return }
        send(.alwaysAllow(of: request), for: id)
    }

    /// Refuses a permission with the fixed text, no reason typed.
    func deny(_ id: UUID) {
        guard permission(id) != nil else { return }
        send(.deny(message: localized("Denied from Cyclop")), for: id)
    }

    /// Approves a plan: the reply repeats the tool's input.
    func approve(_ id: UUID) {
        guard let request = waiting(id), request.kind == .plan else { return }
        send(.approve(plan: request), for: id)
    }

    /// Sends a plan back; Claude revises it and asks again, which arrives as a new request.
    func sendBack(_ id: UUID, remarks: String) {
        guard let request = waiting(id), request.kind == .plan,
            !remarks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        send(.deny(message: remarks), for: id)
    }

    private func waiting(_ id: UUID) -> ClaudeRequest? { requests.first { $0.id == id } }

    private func permission(_ id: UUID) -> ClaudeRequest? { waiting(id).flatMap { $0.kind == .permission ? $0 : nil } }

    // MARK: - Field draft

    /// What is typed in the request's field; nil while the field is not open.
    func draft(of id: UUID) -> String? { drafts[id] }

    /// Opens the field, empty unless a draft is waiting in it.
    func openField(of id: UUID) {
        guard waiting(id) != nil, drafts[id] == nil else { return }
        drafts[id] = ""
    }

    func setDraft(_ text: String, of id: UUID) {
        guard drafts[id] != nil else { return }
        drafts[id] = text
    }

    /// Closes the field and throws its text away.
    func closeField(of id: UUID) { discardDraft(id) }

    private func discardDraft(_ id: UUID) {
        drafts[id] = nil
        if drafts.isEmpty { fieldShown = false }
    }

    /// The pane says whether a field is on screen.
    func setFieldShown(_ shown: Bool) { fieldShown = shown }

    func request(forSession session: ClaudeSession) -> ClaudeRequest? {
        requests.first { $0.pid == session.pid }
    }

    func session(for request: ClaudeRequest) -> ClaudeSession? {
        sessions.first { $0.pid == request.pid }
    }

    /// Prints the reply through the relay, which ends the hook, and takes the request off the list.
    private func send(_ reply: ClaudeReply, for id: UUID) {
        connections[id]?.reply(reply.data)
        drop(id)
    }

    /// The request is over, answered or not. Nothing is left of its text.
    private func drop(_ id: UUID) {
        connections[id] = nil
        missing.remove(id)
        discardDraft(id)
        requests.removeAll { $0.id == id }
        unseen.remove(id)
        hasUnseenRequest = !unseen.isEmpty
    }

    /// The requests now waiting count as seen: the panel is open on them.
    func markSeen() {
        unseen = []
        hasUnseenRequest = false
    }

    /// Takes the request off and closes its relay unanswered, which ends the hook.
    private func withdraw(_ id: UUID) {
        let relay = connections[id]
        drop(id)
        relay?.close()
    }

    /// A request whose session left the list (missing from two reloads in a row: one file that did not
    /// read must not cost an answer), or changed state to anything but waiting after the request
    /// arrived (an answer given in Claude). An older state read late does not count.
    private func withdrawOver(_ alive: [ClaudeSession]) {
        for request in requests {
            guard let session = alive.first(where: { $0.pid == request.pid }) else {
                if missing.contains(request.id) { withdraw(request.id) } else { missing.insert(request.id) }
                continue
            }
            missing.remove(request.id)
            if session.state != .waiting && session.since > request.arrived { withdraw(request.id) }
        }
    }

    /// Every waiting relay is closed without an answer.
    private func closeRequests() {
        let open = Array(connections.values)
        connections = [:]
        missing = []
        drafts = [:]
        fieldShown = false
        requests = []
        markSeen()
        open.forEach { $0.close() }
    }

    // MARK: - Open in Claude

    /// Takes the owner to the session in the app it runs in; where the app
    /// cannot be told apart or has no link, only brings it forward.
    func openInClaude(_ session: ClaudeSession) {
        switch session.place {
        case .app:
            if let id = session.hostSessionID,
                let link = Self.link(scheme: "claude", host: "code", path: "/continue", session: id)
            {
                opener.open(link)
            } else if let app = opener.hostApp(ofProcess: session.pid) {
                opener.bringForward(app)
            }
        case .editor:
            guard let app = opener.hostApp(ofProcess: session.pid) else { return }
            if let scheme = app.urlScheme, let id = session.sessionID,
                let link = Self.link(scheme: scheme, host: "anthropic.claude-code", path: "/open", session: id)
            {
                opener.open(link)
            } else {
                opener.bringForward(app)
            }
        case .terminal:
            if let app = opener.hostApp(ofProcess: session.pid) { opener.bringForward(app) }
        }
    }

    private static func link(scheme: String, host: String, path: String, session: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        components.queryItems = [URLQueryItem(name: "session", value: session)]
        return components.url
    }

    private func session(at url: URL, now: Date) -> ClaudeSession? {
        guard let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(ClaudeSessionFile.self, from: data),
            let session = file.session(fallbackPid: Int(url.deletingPathExtension().lastPathComponent), now: now),
            isAlive(session.pid, file.procStart)
        else { return nil }
        return session
    }
}
