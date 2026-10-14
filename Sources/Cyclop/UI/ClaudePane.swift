import SwiftUI

/// The Claude sessions on this Mac, waiting first; or the request the owner is answering.
struct ClaudePane: View {
    @ObservedObject var store: ClaudeStore
    @ObservedObject var privacy: PrivacyMode
    /// Whether the panel holds the keyboard: asked for only by the press that shows a field.
    @Binding var wantsKeyboard: Bool
    let showSettings: () -> Void
    /// The owner went to the list from a request, and stays there until picking another.
    @State private var showsList = false
    /// The request picked from the list; the oldest one shows when it is gone.
    @State private var picked: UUID?

    var body: some View {
        if let request = shownRequest {
            RequestView(
                request: request, session: store.session(for: request), more: store.requests.count - 1,
                store: store, privacy: privacy, wantsKeyboard: $wantsKeyboard, showList: { showsList = true }
            )
            // Each request starts with its own state: the field closed and empty.
            .id(request.id)
        } else if store.sessions.isEmpty && store.handoffs.isEmpty {
            Text("No Claude sessions")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 3) {
                    if store.listenFailed {
                        Text("Cyclop cannot listen for Claude's requests")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color.yellow.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    ForEach(store.handoffs) { HandoffRow(status: $0, store: store, privacy: privacy) }
                    ForEach(store.sessions) { row($0) }
                }
                .padding(.vertical, 4)
            }
            .padding(.top, 2)
        }
    }

    /// With requests waiting the pane opens on the oldest, unless the owner chose another or the list.
    private var shownRequest: ClaudeRequest? {
        guard !showsList else { return nil }
        return store.requests.first { $0.id == picked } ?? store.requests.first
    }

    private func row(_ session: ClaudeSession) -> some View {
        let request = store.request(forSession: session)
        return SessionRow(
            session: session, store: store, privacy: privacy, invites: session.state == .waiting && store.connection != .connected,
            showSettings: showSettings,
            open: {
                if let request {
                    picked = request.id
                    showsList = false
                } else {
                    store.openInClaude(session)
                }
            }
        )
    }
}

/// One plan handed off to a new session: under way, opened (it leaves by itself), or failed.
private struct HandoffRow: View {
    let status: ClaudeHandoffStatus
    let store: ClaudeStore
    @ObservedObject var privacy: PrivacyMode
    @State private var hovering = false

    private var key: String { "claude.handoff.\(status.id)" }
    private var hidden: Bool { privacy.hides(.claude, key) }
    private var seed: UInt64 { UInt64(bitPattern: Int64(status.id.uuidString.hashValue)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                icon
                    .frame(width: 12)
                line
                Spacer(minLength: 6)
                // Only where something is covered: the session's name while preparing, the reason and the buttons after a failure.
                if hovering, privacy.covers(.claude), status.phase != .opened {
                    RevealEye(hidden: hidden) { privacy.toggle(key) }
                }
            }
            if case .failed = status.phase {
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    if status.command != nil {
                        HandoffButton(title: localized("Copy Command")) { store.copyCommand(of: status.id) }
                            .allowsHitTesting(!hidden)
                    }
                    HandoffButton(title: localized("Dismiss")) { store.dismissHandoff(status.id) }
                        .allowsHitTesting(!hidden)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
        .onHover { hovering = $0 }
        .animation(Theme.contentAnimation, value: hovering)
    }

    @ViewBuilder
    private var icon: some View {
        switch status.phase {
        case .preparing:
            ProgressView().controlSize(.mini).scaleEffect(0.7)
        case .opened:
            Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.yellow.opacity(0.85))
        }
    }

    @ViewBuilder
    private var line: some View {
        switch status.phase {
        case .preparing:
            covered(
                status.place == .terminal
                    ? localized("Opening a terminal for «%@»…") : localized("Preparing a session for «%@»…"),
                status.sessionName, color: .white, lines: 1)
        case .opened:
            Text(verbatim: openedText).font(.system(size: 10.5)).foregroundStyle(.white)
        case .failed(let failure):
            covered(
                localized("Could not hand the plan off: %@"), Self.reason(failure), color: Color.yellow.opacity(0.85), lines: 3)
        }
    }

    /// The localized format with a value in it (the session's name, a failure's reason), which Hide Contents covers.
    @ViewBuilder
    private func covered(_ format: String, _ value: String, color: Color, lines: Int) -> some View {
        if hidden {
            let parts = format.components(separatedBy: "%@")
            HStack(spacing: 3) {
                Text(verbatim: parts.first ?? "").font(.system(size: 10.5)).foregroundStyle(color)
                SpoilerField(seed: seed)
                    .frame(width: 56, height: 10)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .accessibilityLabel(Text(localized("Hidden")))
                Text(verbatim: parts.last ?? "").font(.system(size: 10.5)).foregroundStyle(color)
            }
        } else {
            Text(verbatim: String(format: format, value))
                .font(.system(size: 10.5))
                .foregroundStyle(color)
                .lineLimit(lines)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: lines > 1)
        }
    }

    private var openedText: String {
        switch status.place {
        case .app: return localized("Opened in Claude. Type go there to start.")
        case .editor: return localized("Opened in the editor. Choose the mode there and type go to start.")
        case .terminal: return localized("Started in the terminal.")
        }
    }

    private static func reason(_ failure: ClaudeHandoffFailure) -> String {
        switch failure {
        case .automationDenied: return localized("Automation is not allowed")
        case .terminalFailed: return localized("The terminal did not run the command")
        case .noLink: return localized("The session was made but cannot be opened from here")
        case .noExecutable: return localized("No claude executable found")
        case .timedOut: return localized("It took too long")
        case .step(let text): return text
        case .exitStatus(let code): return localized("claude exited with status %d", Int(code))
        }
    }
}

private struct HandoffButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 20)
                .background(Capsule().fill(Theme.surfaceHover))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct SessionRow: View {
    let session: ClaudeSession
    let store: ClaudeStore
    @ObservedObject var privacy: PrivacyMode
    /// A waiting session while Cyclop cannot answer for it: a line leads to Settings.
    let invites: Bool
    let showSettings: () -> Void
    let open: () -> Void
    @State private var hovering = false

    private var rowKey: String { "claude.session.\(session.pid)" }
    private var hidden: Bool { privacy.hides(.claude, rowKey) }

    var body: some View {
        VStack(spacing: 0) {
            main
            if invites {
                Button(action: showSettings) {
                    Text("Connect in Settings to answer here")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.orange.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .frame(height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Theme.surfaceHover : Theme.surface)
        )
        .onHover { hovering = $0 }
        .animation(Theme.contentAnimation, value: hovering)
    }

    private var main: some View {
        HStack(spacing: 9) {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                SpoilerText(
                    text: session.name, hidden: hidden, font: .system(size: 11, weight: .medium),
                    height: 11, seed: UInt64(truncatingIfNeeded: session.pid) &* 0x9E3779B97F4A7C15)
                SpoilerText(
                    text: Self.shortened(session.folder), hidden: hidden, font: .system(size: 9),
                    color: Theme.tertiary, height: 9, seed: UInt64(truncatingIfNeeded: session.pid) &+ 7)
            }
            Spacer(minLength: 6)
            if hovering, privacy.covers(.claude) {
                RevealEye(hidden: hidden) { privacy.toggle(rowKey) }
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(stateLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(color)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(verbatim: "\(placeLabel) · \(Self.duration(context.date.timeIntervalSince(session.since)))")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 36)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .help(store.request(forSession: session) == nil ? localized("Open in Claude") : localized("Answer"))
    }

    private var color: Color {
        switch session.state {
        case .working: return .accentColor
        case .waiting: return .orange
        case .idle: return Theme.tertiary
        }
    }

    private var stateLabel: String {
        switch session.state {
        case .working: return localized("working")
        case .waiting: return localized("waiting")
        case .idle: return localized("idle")
        }
    }

    private var placeLabel: String {
        switch session.place {
        case .app: return localized("Claude app")
        case .editor: return localized("Editor")
        case .terminal: return localized("Terminal")
        }
    }

    private static func shortened(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// `42 s`, `5 min`, `2 h 5 min`, in the app's language.
    private static func duration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: appLanguage)
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        formatter.allowedUnits = interval < 3600 ? [.minute, .second] : [.hour, .minute]
        formatter.maximumUnitCount = interval < 3600 ? 1 : 2
        return formatter.string(from: max(0, interval)) ?? ""
    }
}

/// One request: whose it is, what it asks, and the buttons that answer it.
private struct RequestView: View {
    let request: ClaudeRequest
    let session: ClaudeSession?
    /// How many requests wait besides this one.
    let more: Int
    let store: ClaudeStore
    @ObservedObject var privacy: PrivacyMode
    @Binding var wantsKeyboard: Bool
    let showList: () -> Void

    private var key: String { "claude.request.\(request.id)" }
    /// The text of this request is under the dust, and its buttons do nothing until it is shown.
    private var hidden: Bool { privacy.hides(.claude, key) }
    private var seed: UInt64 { UInt64(bitPattern: Int64(request.id.uuidString.hashValue)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if more > 0 { moreLine }
            header
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    if let question = request.current {
                        QuestionView(
                            request: request, question: question, store: store, hidden: hidden, seed: seed,
                            wantsKeyboard: $wantsKeyboard
                        )
                        // A new question starts with its own state: the field closed.
                        .id(request.answers.count)
                    } else if request.kind == .permission {
                        PermissionCard(request: request, store: store, hidden: hidden, seed: seed)
                    } else if request.kind == .plan {
                        PlanCard(
                            request: request, store: store, hidden: hidden, seed: seed,
                            wantsKeyboard: $wantsKeyboard, open: openInClaude)
                    } else {
                        elsewhere
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 4)
    }

    private var moreLine: some View {
        Button(action: showList) {
            Text(more == 1 ? localized("1 more request · list") : localized("%d more requests · list", more))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(Capsule().fill(Theme.surface))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.orange).frame(width: 7, height: 7)
            SpoilerText(
                text: session?.name ?? "Claude", hidden: hidden && session != nil,
                font: .system(size: 11, weight: .medium), height: 11, seed: seed)
            Spacer(minLength: 6)
            if privacy.covers(.claude) {
                RevealEye(hidden: hidden) { privacy.toggle(key) }
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            if request.current != nil || request.kind == .permission {
                Button { openInClaude() } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(localized("Open in Claude"))
            }
        }
    }

    /// A question that is not answered with buttons here: one that takes several options.
    @ViewBuilder
    private var elsewhere: some View {
        if let text = request.questions.first?.text {
            CoverableText(
                text: text, hidden: hidden, font: .system(size: 12, weight: .medium), height: 28, seed: seed)
        }
        Text("This question takes several options: answer it in Claude")
            .font(.system(size: 10))
            .foregroundStyle(Theme.secondary)
        CardButton(title: localized("Open in Claude"), action: openInClaude)
            .allowsHitTesting(!hidden)
    }

    private func openInClaude() {
        if let session, !hidden { store.openInClaude(session) }
    }
}

/// The question the request is on: one button per option, and a way back through several.
private struct QuestionView: View {
    let request: ClaudeRequest
    let question: ClaudeQuestion
    let store: ClaudeStore
    /// Covered by Hide Contents: the texts are dust and the answers do nothing.
    let hidden: Bool
    let seed: UInt64
    @Binding var wantsKeyboard: Bool
    /// The field is open; after a collapse the pane is built again and finds the draft in the store.
    @State private var typing: Bool

    init(
        request: ClaudeRequest, question: ClaudeQuestion, store: ClaudeStore, hidden: Bool, seed: UInt64,
        wantsKeyboard: Binding<Bool>
    ) {
        self.request = request
        self.question = question
        self.store = store
        self.hidden = hidden
        self.seed = seed
        _wantsKeyboard = wantsKeyboard
        _typing = State(initialValue: store.draft(of: request.id) != nil)
    }

    var body: some View {
        if request.questions.count > 1 {
            HStack(spacing: 6) {
                if !request.answers.isEmpty {
                    Button { store.goBack(request.id) } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text(localized("Question %d of %d", request.answers.count + 1, request.questions.count))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            .allowsHitTesting(!hidden)
        }
        if let header = question.header, !hidden {
            Text(verbatim: header.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.tertiary)
        }
        CoverableText(text: question.text, hidden: hidden, font: .system(size: 12, weight: .medium), height: 28, seed: seed)
        VStack(spacing: 3) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                OptionButton(option: option, hidden: hidden, seed: seed &+ UInt64(index)) {
                    store.answer(request.id, with: option.label)
                }
            }
            if typing && !hidden {
                DraftField(
                    id: request.id, placeholder: localized("Your answer"), store: store, wantsKeyboard: $wantsKeyboard,
                    send: { store.answer(request.id, with: $0) }, cancel: { typing = false })
            } else {
                OwnAnswerButton {
                    store.openField(of: request.id)
                    typing = true
                    wantsKeyboard = true
                }
            }
        }
        .allowsHitTesting(!hidden)
    }
}

/// Text of a request that may be several lines: shown, or a field of dust of a fixed height
/// (the length of what is covered is not given away).
private struct CoverableText: View {
    let text: String
    let hidden: Bool
    var font: Font = .system(size: 11)
    var color: Color = .white
    var height: CGFloat = 28
    var lineLimit: Int?
    var seed: UInt64 = 0x9E3779B97F4A7C15

    var body: some View {
        if hidden {
            SpoilerField(seed: seed)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .accessibilityLabel(Text(localized("Hidden")))
        } else {
            Text(verbatim: text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(lineLimit)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OwnAnswerButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(localized("Own Answer…"), systemImage: "pencil")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(hovering ? Theme.secondary : Theme.hairline, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.contentAnimation, value: hovering)
    }
}

/// One line the owner types into: Return sends, Esc cancels. The text lives in the store
/// (not published), so a collapse keeps it; the keyboard is asked for by the press that shows this.
private struct DraftField: View {
    let id: UUID
    let placeholder: String
    let store: ClaudeStore
    @Binding var wantsKeyboard: Bool
    let send: (String) -> Void
    let cancel: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(
        id: UUID, placeholder: String, store: ClaudeStore, wantsKeyboard: Binding<Bool>,
        send: @escaping (String) -> Void, cancel: @escaping () -> Void
    ) {
        self.id = id
        self.placeholder = placeholder
        self.store = store
        _wantsKeyboard = wantsKeyboard
        self.send = send
        self.cancel = cancel
        _text = State(initialValue: store.draft(of: id) ?? "")
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(.white)
            .tint(Theme.secondary)
            .focused($focused)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
            .onChange(of: text) { _, new in store.setDraft(new, of: id) }
            .onSubmit {
                let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !typed.isEmpty { send(typed) }
            }
            .onKeyPress(.escape) {
                store.closeField(of: id)
                wantsKeyboard = false
                cancel()
                return .handled
            }
            .onAppear {
                store.setFieldShown(true)
                focused = wantsKeyboard
                // A pass later: a focus asked for while the pane is still going on screen is dropped.
                DispatchQueue.main.async { focused = wantsKeyboard }
            }
            .onChange(of: wantsKeyboard) { _, wants in focused = wants }
            // Sent, cancelled, the request gone: the keyboard goes back with the field.
            .onDisappear {
                store.setFieldShown(false)
                wantsKeyboard = false
            }
    }
}

/// A full-width capsule, the same for every card's buttons.
private struct CardButton: View {
    let title: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(prominent ? Color.black : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(Capsule().fill(prominent ? Color.white.opacity(0.9) : Theme.surfaceHover))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A permission: the tool, what it touches, and the three answers.
private struct PermissionCard: View {
    let request: ClaudeRequest
    let store: ClaudeStore
    let hidden: Bool
    let seed: UInt64

    var body: some View {
        Text(verbatim: request.toolName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
        Group {
            if hidden {
                SpoilerField(seed: seed)
                    .frame(height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityLabel(Text(localized("Hidden")))
            } else {
                Text(verbatim: request.detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
            }
        }
        if let rule = request.rule, !hidden {
            Text(localized("Always Allow: %@", rule))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        HStack(spacing: 4) {
            CardButton(title: localized("Allow"), prominent: true) { store.allow(request.id) }
            if request.rule != nil {
                CardButton(title: localized("Always Allow")) { store.alwaysAllow(request.id) }
            }
            CardButton(title: localized("Deny")) { store.deny(request.id) }
        }
        .allowsHitTesting(!hidden)
    }
}

/// A plan: enough of it to recognise, the three answers, and under them how it goes on. Reading it is for Claude's window.
private struct PlanCard: View {
    let request: ClaudeRequest
    @ObservedObject var store: ClaudeStore
    let hidden: Bool
    let seed: UInt64
    @Binding var wantsKeyboard: Bool
    let open: () -> Void
    @State private var remarking: Bool
    /// The choice rows are open; they stand in for the plan's beginning.
    @State private var expanded: Bool

    init(
        request: ClaudeRequest, store: ClaudeStore, hidden: Bool, seed: UInt64, wantsKeyboard: Binding<Bool>,
        open: @escaping () -> Void
    ) {
        self.request = request
        self.store = store
        self.hidden = hidden
        self.seed = seed
        _wantsKeyboard = wantsKeyboard
        self.open = open
        _remarking = State(initialValue: store.draft(of: request.id) != nil)
        _expanded = State(initialValue: store.choiceExpanded(of: request.id))
    }

    var body: some View {
        CoverableText(
            text: request.planTitle.isEmpty ? localized("Plan") : request.planTitle, hidden: hidden,
            font: .system(size: 12, weight: .medium), height: 14, lineLimit: 2, seed: seed)
        if expanded {
            PlanChoiceRows(id: request.id, store: store)
                .allowsHitTesting(!hidden)
        } else if !request.planBeginning.isEmpty {
            CoverableText(
                text: request.planBeginning, hidden: hidden, font: .system(size: 10), color: Theme.secondary,
                height: 56, lineLimit: 8, seed: seed &+ 1)
        }
        if remarking && !hidden {
            DraftField(
                id: request.id, placeholder: localized("Remarks"), store: store, wantsKeyboard: $wantsKeyboard,
                send: { store.sendBack(request.id, remarks: $0) }, cancel: { remarking = false })
        }
        HStack(spacing: 4) {
            CardButton(title: localized("Open in Claude"), action: open)
            CardButton(title: localized("Approve"), prominent: true) { store.approve(request.id) }
            CardButton(title: localized("Send Back with Remarks…")) {
                store.openField(of: request.id)
                remarking = true
                wantsKeyboard = true
            }
        }
        .allowsHitTesting(!hidden)
        PlanSummaryLine(id: request.id, store: store, expanded: expanded) {
            expanded.toggle()
            store.setChoiceExpanded(expanded, of: request.id)
        }
        .allowsHitTesting(!hidden)
    }
}

/// How the plan will go on, in one line; pressing it opens the choice rows.
private struct PlanSummaryLine: View {
    let id: UUID
    @ObservedObject var store: ClaudeStore
    let expanded: Bool
    let toggle: () -> Void

    private var summary: String {
        let choice = store.planChoice(of: id)
        var parts: [String]
        if store.planRoute(of: id) == .inPlace {
            parts = [localized("In this session")]
        } else {
            let model: String
            switch choice.model {
            case .sonnet: model = "Sonnet"
            case .same: model = PlanChoiceLabels.shortModel(store.sessionModel(of: id)) ?? localized("Same")
            }
            parts = [choice.context.label, model]
            // Claude and the editor ask for the effort themselves when the session opens, the editor for the mode too.
            if store.preparedHandoffPlace(of: id) == nil { parts.append(choice.effort.rawValue) }
        }
        switch store.preparedHandoffPlace(of: id) {
        case .app: parts.append(ClaudeHandoff.preparedMode(choice.mode, in: .app).title)
        case .editor: break
        case .terminal, nil: parts.append(choice.mode.title)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(verbatim: summary)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                Spacer(minLength: 0)
            }
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Theme.contentAnimation, value: expanded)
    }
}

/// The four choices of a plan request, for this request only.
private struct PlanChoiceRows: View {
    let id: UUID
    @ObservedObject var store: ClaudeStore

    private func binding<Value>(_ keyPath: WritableKeyPath<PlanChoice, Value>) -> Binding<Value> {
        Binding(
            get: { store.planChoice(of: id)[keyPath: keyPath] },
            set: {
                var choice = store.planChoice(of: id)
                choice[keyPath: keyPath] = $0
                store.setPlanChoice(choice, of: id)
            })
    }

    var body: some View {
        let route = store.planRoute(of: id)
        let unavailable = store.handoffUnavailable(of: id)
        let offered = unavailable == nil
        let model = store.sessionModel(of: id)
        let bypassOff = route == .inPlace && !store.bypassAllowed(of: id)
        let prepared = store.preparedHandoffPlace(of: id)
        VStack(alignment: .leading, spacing: 3) {
            PlanChoiceRow(title: localized("Context")) {
                NotchSegmented(
                    selection: binding(\.context), options: PlanChoice.Context.allCases, label: { $0.label },
                    disabled: offered ? [] : Set(PlanChoice.Context.allCases))
            }
            if !ClaudeHandoff.isSonnet(model) {
                PlanChoiceRow(title: localized("Model")) {
                    NotchSegmented(
                        selection: binding(\.model), options: PlanChoice.ModelChoice.allCases,
                        label: { $0.label(sessionModel: model) },
                        disabled: offered ? [] : Set(PlanChoice.ModelChoice.allCases))
                }
            }
            if let unavailable {
                PlanChoiceNote(
                    text: unavailable == .noExecutable
                        ? localized("No claude executable found") : localized("Only in this session here"))
            }
            if prepared == .editor {
                PlanChoiceNote(text: localized("Effort and mode are chosen in the editor when the session opens"))
            } else {
                if route == .handoff && prepared == nil {
                    PlanChoiceRow(title: localized("Effort")) {
                        NotchSegmented(
                            selection: binding(\.effort), options: PlanChoice.Effort.allCases, label: { $0.rawValue })
                    }
                }
                PlanChoiceRow(title: localized("Mode")) {
                    NotchSegmented(
                        selection: binding(\.mode), options: PlanChoice.Mode.allCases, label: { $0.label },
                        disabled: bypassOff ? [.bypassPermissions] : [])
                }
                if bypassOff {
                    PlanChoiceNote(text: localized("Not allowed in this session"))
                }
                if prepared == .app {
                    if store.planChoice(of: id).mode == .bypassPermissions {
                        PlanChoiceNote(text: localized("Claude opens bypass as accept edits"))
                    }
                    PlanChoiceNote(text: localized("Effort is chosen in Claude when the session opens"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A caption on the left and the control on the right; the Settings page draws the same rows larger.
struct PlanChoiceRow<Control: View>: View {
    let title: String
    var inSettings = false
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: inSettings ? 8 : 6) {
            // The icon column of the other rows of the Settings card.
            if inSettings { Color.clear.frame(width: 16, height: 1) }
            Text(title)
                .font(.system(size: inSettings ? 11.5 : 10, weight: inSettings ? .medium : .regular))
                .foregroundStyle(inSettings ? Color.white : Theme.secondary)
                .lineLimit(1)
                .frame(width: inSettings ? nil : 56, alignment: .leading)
            if inSettings { Spacer(minLength: 8) }
            control()
                .frame(maxWidth: inSettings ? 330 : .infinity)
        }
    }
}

private struct PlanChoiceNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(Theme.tertiary)
            .padding(.leading, 62)
    }
}

/// The words of the plan choice; the case names themselves are Claude Code's.
extension PlanChoice.Context {
    var label: String {
        switch self {
        case .keep: return localized("Keep")
        case .compact: return localized("Compact")
        case .clear: return localized("Clear")
        }
    }
}

extension PlanChoice.ModelChoice {
    /// "Same" with the session's model in brackets when the transcript named one.
    func label(sessionModel: String?) -> String {
        switch self {
        case .sonnet: return "Sonnet"
        case .same:
            guard let name = PlanChoiceLabels.shortModel(sessionModel) else { return localized("Same") }
            return localized("Same (%@)", name)
        }
    }
}

extension PlanChoice.Mode {
    /// For a segment.
    var label: String {
        switch self {
        case .bypassPermissions: return localized("Bypass")
        case .auto: return localized("Auto")
        case .acceptEdits: return localized("Edits")
        case .default: return localized("Ask")
        }
    }

    /// For the summary line.
    var title: String {
        switch self {
        case .bypassPermissions: return localized("Bypass permissions")
        case .auto: return localized("Auto")
        case .acceptEdits: return localized("Accept edits")
        case .default: return localized("Ask")
        }
    }
}

enum PlanChoiceLabels {
    /// `claude-sonnet-5-5` is `Sonnet 5.5`; nil when the id has no family name.
    static func shortModel(_ id: String?) -> String? {
        guard var id = id?.lowercased() else { return nil }
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        if id.hasPrefix("claude-") { id.removeFirst("claude-".count) }
        let parts = id.split(separator: "-").map(String.init).filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
        let family = parts.filter { $0.contains { $0.isLetter } }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let version = parts.filter { $0.allSatisfy(\.isNumber) }
        guard !family.isEmpty else { return nil }
        return (family + (version.isEmpty ? [] : [version.joined(separator: ".")])).joined(separator: " ")
    }
}

private struct OptionButton: View {
    let option: ClaudeQuestion.Option
    let hidden: Bool
    let seed: UInt64
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                if hidden {
                    SpoilerField(seed: seed)
                        .frame(height: 12)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .accessibilityLabel(Text(localized("Hidden")))
                } else {
                    Text(verbatim: option.label)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white)
                    if !option.description.isEmpty {
                        Text(verbatim: option.description)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Theme.surfaceHover : Theme.surface)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.contentAnimation, value: hovering)
    }
}
