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
    /// What the owner sees of each hand-off of an approved plan, oldest first. In memory only.
    @Published private(set) var handoffs: [ClaudeHandoffStatus] = []

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
    private let runner: any ClaudeRunning
    private let defaultPlanChoice: () -> PlanChoice
    private let transcriptModel: (URL) -> String?
    private let processArguments: (Int) -> [String]?
    private let executable: (Int) -> URL?
    private let newSessionID: () -> String
    private let waitForIdle: TimeInterval
    private let handoffLinger: TimeInterval
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
    /// The choice of each plan request, as set; `planChoice(of:)` is what it comes to.
    @Published private var choices: [UUID: PlanChoice] = [:]
    /// The plan requests whose choice rows are open on the card; not published, the card keeps its own copy.
    private var choiceOpen: Set<UUID> = []
    /// What was known of each plan request's session when it arrived.
    private var facts: [UUID: PlanFacts] = [:]
    private var handoffTasks: [UUID: Task<Void, Never>] = [:]
    private var lingerTasks: [UUID: Task<Void, Never>] = [:]

    private struct PlanFacts {
        var sessionModel: String?
        var bypassAllowed: Bool
        var unavailable: HandoffUnavailable?
        var place: ClaudeSession.Place
        var host: ClaudeHostApp?
        /// The `claude` that prepares a Claude app or editor session; nil for a terminal and where none was found.
        var executable: URL?
        var sessionName: String
        var folder: String
        var transcript: String
    }

    init(
        folder: URL = ClaudeStore.defaultFolder,
        isAlive: @escaping (Int, String?) -> Bool = ProcessTable.isAlive(pid:procStart:),
        opener: ClaudeOpening = SystemClaudeOpener(),
        settings: ClaudeSettingsFile = .standard,
        command: String = ClaudeSettingsEdit.command(
            forExecutable: Bundle.main.executablePath ?? CommandLine.arguments[0]),
        listener: any ClaudeListening = SocketListening(),
        now: @escaping () -> Date = Date.init,
        runner: any ClaudeRunning = SystemClaudeRunner(),
        defaultPlanChoice: @escaping () -> PlanChoice = { PlanChoice() },
        transcriptModel: @escaping (URL) -> String? = { ClaudeHandoff.lastModel(ofFile: $0) },
        processArguments: @escaping (Int) -> [String]? = { ProcessTable.arguments(of: $0) },
        executable: @escaping (Int) -> URL? = ClaudeStore.claudeExecutable(ofProcess:),
        newSessionID: @escaping () -> String = { UUID().uuidString.lowercased() },
        waitForIdle: TimeInterval = 5,
        handoffLinger: TimeInterval = 8
    ) {
        self.folder = folder
        self.isAlive = isAlive
        self.opener = opener
        self.settings = settings
        self.command = command
        self.listener = listener
        self.now = now
        self.runner = runner
        self.defaultPlanChoice = defaultPlanChoice
        self.transcriptModel = transcriptModel
        self.processArguments = processArguments
        self.executable = executable
        self.newSessionID = newSessionID
        self.waitForIdle = waitForIdle
        self.handoffLinger = handoffLinger
    }

    /// The `claude` to run for a session: its own process's when that is one, else a usual place.
    nonisolated static func claudeExecutable(ofProcess pid: Int) -> URL? {
        ClaudeHandoff.executable(
            processPath: ProcessTable.executablePath(of: pid),
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            exists: { FileManager.default.isExecutableFile(atPath: $0) })
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
        if request.kind == .plan {
            choices[request.id] = defaultPlanChoice()
            facts[request.id] = planFacts(of: request, session: known.first { $0.pid == request.pid })
        }
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

    /// Approves a plan the way its choice says: in its session, with the mode, or by a hand-off.
    func approve(_ id: UUID) {
        guard let request = waiting(id), request.kind == .plan, let known = facts[id] else { return }
        let choice = planChoice(of: id)
        guard planRoute(of: id) == .handoff else {
            send(.approve(plan: request, mode: choice.mode), for: id)
            return
        }
        let handoff = ClaudeHandoff(
            choice: choice, sessionModel: known.sessionModel, folder: known.folder, sessionID: request.sessionID,
            newSessionID: newSessionID(), planFile: request.planFilePath ?? "", transcript: known.transcript)
        let name = session(for: request)?.name ?? known.sessionName
        send(.interrupt(message: ClaudeHandoff.interruptMessage), for: id)
        startHandoff(handoff, of: name, facts: known, pid: request.pid)
    }

    /// Sends a plan back; Claude revises it and asks again, which arrives as a new request.
    func sendBack(_ id: UUID, remarks: String) {
        guard let request = waiting(id), request.kind == .plan,
            !remarks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        send(.deny(message: remarks), for: id)
    }

    // MARK: - Plan choice

    /// What Approve does with this plan: the choice as set, but with the context and the model left alone where a
    /// hand-off is not offered, and bypass turned into accept edits where the session cannot take it.
    func planChoice(of id: UUID) -> PlanChoice {
        guard var choice = choices[id], let known = facts[id] else { return defaultPlanChoice() }
        if known.unavailable != nil {
            choice.context = .keep
            choice.model = .same
        }
        if choice.route(sessionModel: known.sessionModel) == .inPlace, choice.mode == .bypassPermissions, !known.bypassAllowed {
            choice.mode = .acceptEdits
        }
        return choice
    }

    /// Changes the choice of a plan request. A mode left as `planChoice(of:)` showed it keeps the one set.
    func setPlanChoice(_ choice: PlanChoice, of id: UUID) {
        guard let set = choices[id] else { return }
        var updated = choice
        if choice.mode == planChoice(of: id).mode { updated.mode = set.mode }
        choices[id] = updated
    }

    /// Whether the card shows the choice rows; kept here so a collapse of the panel does not close them.
    func choiceExpanded(of id: UUID) -> Bool { choiceOpen.contains(id) }

    func setChoiceExpanded(_ expanded: Bool, of id: UUID) {
        if expanded { choiceOpen.insert(id) } else { choiceOpen.remove(id) }
    }

    func planRoute(of id: UUID) -> PlanRoute {
        facts[id].map { planChoice(of: id).route(sessionModel: $0.sessionModel) } ?? .inPlace
    }

    /// Claude or the editor when Approve hands the plan off to a session prepared for it, where the effort (and,
    /// in the editor, the mode) is chosen when the session opens; nil otherwise.
    func preparedHandoffPlace(of id: UUID) -> ClaudeSession.Place? {
        guard planRoute(of: id) == .handoff, let place = facts[id]?.place, place != .terminal else { return nil }
        return place
    }

    /// Nil when a hand-off is offered for this plan; else why not.
    func handoffUnavailable(of id: UUID) -> HandoffUnavailable? { facts[id]?.unavailable }

    /// The session's model id as the transcript's tail names it; nil when unknown.
    func sessionModel(of id: UUID) -> String? { facts[id]?.sessionModel }

    /// Whether the session can be switched into bypass permissions.
    func bypassAllowed(of id: UUID) -> Bool { facts[id]?.bypassAllowed ?? false }

    private func planFacts(of request: ClaudeRequest, session: ClaudeSession?) -> PlanFacts {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folder = request.cwd ?? session?.folder ?? ""
        let place = session?.place ?? .terminal
        let host = opener.hostApp(ofProcess: request.pid)
        let transcript = request.transcriptPath.map { ($0 as NSString).expandingTildeInPath }
            ?? ClaudeHandoff.transcriptPath(folder: folder, sessionID: request.sessionID, home: home)
        let claude = place == .terminal ? nil : executable(request.pid)
        return PlanFacts(
            sessionModel: transcriptModel(URL(fileURLWithPath: transcript)),
            bypassAllowed: processArguments(request.pid).map { ClaudeHandoff.allowsBypass(arguments: $0) } ?? false,
            unavailable: ClaudeHandoff.unavailable(
                planFile: request.planFilePath, agentID: request.agentID, folder: folder, place: place,
                hostBundleID: host?.bundleID, hostURLScheme: host?.urlScheme,
                typed: [request.sessionID, transcript], hasExecutable: place == .terminal || claude != nil),
            place: place, host: host, executable: claude, sessionName: session?.name ?? "Claude", folder: folder,
            transcript: transcript)
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
        choices[id] = nil
        choiceOpen.remove(id)
        facts[id] = nil
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
        choices = [:]
        choiceOpen = []
        facts = [:]
        missing = []
        drafts = [:]
        fieldShown = false
        requests = []
        markSeen()
        open.forEach { $0.close() }
    }

    // MARK: - Hand-off

    /// Removes a hand-off row: a failed one the owner dismissed, or any other.
    func dismissHandoff(_ id: UUID) {
        lingerTasks[id]?.cancel()
        lingerTasks[id] = nil
        handoffs.removeAll { $0.id == id }
    }

    /// Puts the terminal hand-off's command on the pasteboard.
    func copyCommand(of id: UUID) {
        guard let command = handoffs.first(where: { $0.id == id })?.command else { return }
        opener.copyToPasteboard(command)
    }

    /// Resolves once every hand-off under way has ended; for tests.
    func waitForHandoffs() async {
        for task in Array(handoffTasks.values) { await task.value }
    }

    private func startHandoff(_ handoff: ClaudeHandoff, of name: String, facts: PlanFacts, pid: Int) {
        let terminal = facts.place == .terminal
        let status = ClaudeHandoffStatus(
            sessionName: name, place: facts.place, phase: .preparing, command: terminal ? handoff.shellCommand : nil)
        handoffs.append(status)
        let id = status.id
        handoffTasks[id] = Task { [weak self] in
            await self?.perform(handoff, status: id, facts: facts, pid: pid)
            self?.handoffTasks[id] = nil
        }
    }

    private func perform(_ handoff: ClaudeHandoff, status id: UUID, facts: PlanFacts, pid: Int) async {
        await waitUntilNotWaiting(pid)
        switch facts.place {
        case .terminal:
            guard let host = facts.host else { return finish(id, .failed(.terminalFailed)) }
            switch await opener.runInTerminal(handoff.shellCommand, besideProcess: pid, in: host) {
            case .done: break
            case .automationDenied: return finish(id, .failed(.automationDenied))
            case .failed: return finish(id, .failed(.terminalFailed))
            }
        case .app, .editor:
            if let failure = await prepare(handoff, facts: facts) { return finish(id, .failed(failure)) }
            guard let link = Self.sessionLink(for: handoff.newSessionID, place: facts.place, host: facts.host) else {
                return finish(id, .failed(.noLink))
            }
            opener.open(link)
        }
        finish(id, .opened)
    }

    /// Runs the steps that make the new session; the first failure, if any.
    private func prepare(_ handoff: ClaudeHandoff, facts: PlanFacts) async -> ClaudeHandoffFailure? {
        // A hand-off is offered only with an executable (unavailable otherwise); this is a guard.
        guard let executable = facts.executable else { return .noExecutable }
        let environment = ClaudeHandoff.scrubbedEnvironment(ProcessInfo.processInfo.environment)
        for arguments in handoff.headlessSteps(in: facts.place) {
            let run = await runner.run(
                executable: executable, arguments: arguments, folder: URL(fileURLWithPath: handoff.folder, isDirectory: true),
                environment: environment, timeout: 600)
            if run.timedOut { return .timedOut }
            if run.status != 0 {
                let reason = ClaudeHandoff.reason(ofStandardError: run.standardError)
                return reason.isEmpty ? .exitStatus(run.status) : .step(reason)
            }
        }
        return nil
    }

    /// The hook has been answered; the session's file may still say it waits.
    private func waitUntilNotWaiting(_ pid: Int) async {
        guard running else { return }
        let deadline = Date().addingTimeInterval(waitForIdle)
        while true {
            reload()
            if sessions.first(where: { $0.pid == pid })?.state != .waiting || Date() >= deadline { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func finish(_ id: UUID, _ phase: ClaudeHandoffStatus.Phase) {
        guard let index = handoffs.firstIndex(where: { $0.id == id }) else { return }
        handoffs[index].phase = phase
        guard phase == .opened else { return }
        lingerTasks[id] = Task { [weak self, handoffLinger] in
            try? await Task.sleep(for: .seconds(handoffLinger))
            guard !Task.isCancelled else { return }
            self?.dismissHandoff(id)
        }
    }

    /// Where the prepared session opens: the Claude app, or the editor's own link.
    private static func sessionLink(for id: String, place: ClaudeSession.Place, host: ClaudeHostApp?) -> URL? {
        switch place {
        case .app: return link(scheme: "claude", host: "resume", path: "", session: id)
        case .editor: return host?.urlScheme.flatMap { link(scheme: $0, host: "anthropic.claude-code", path: "/open", session: id) }
        case .terminal: return nil
        }
    }

    // MARK: - Open in Claude

    /// Takes the owner to the session in the app it runs in; where the app
    /// cannot be told apart or has no link, only brings it forward. In a terminal
    /// the session's own tab is selected when macOS allows it.
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
            guard let app = opener.hostApp(ofProcess: session.pid) else { return }
            if !opener.focusTab(ofProcess: session.pid, in: app) { opener.bringForward(app) }
        }
    }

    private static func link(scheme: String, host: String, path: String, session: String) -> URL? {
        // URLComponents traps on a scheme that is not one.
        guard scheme.wholeMatch(of: /[A-Za-z][A-Za-z0-9+.-]*/) != nil else { return nil }
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
