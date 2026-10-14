import SwiftUI

/// Left: the record button and a meter per track. Right: the journal, newest first.
struct MeetingsPane: View {
    @ObservedObject var store: MeetingStore

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            controls.frame(width: 168)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            journal
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 2)
        .onAppear { store.reload() }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Button {
                if store.recording != nil {
                    store.stopRecording()
                } else {
                    Task { await store.startRecording() }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: store.recording == nil ? "record.circle" : "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(store.recording == nil ? "Start Recording" : "Stop")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(Capsule().fill(store.recording == nil ? Color.accentColor : Color.red))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            if case .ready = store.models {
            } else {
                modelsNotice
            }
            if store.recording != nil {
                meters
            } else if store.microphoneDenied {
                notice("Microphone access is off", action: "Open Settings") {
                    store.openMicrophoneSettings()
                }
            } else if store.startFailed {
                notice("Recording could not start", action: nil) {}
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var modelsNotice: some View {
        switch store.models {
        case .downloading(let fraction):
            VStack(spacing: 4) {
                ProgressView(value: fraction).controlSize(.small)
                Text(localized("Downloading %d%%", Int(fraction * 100)))
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
        case .missing, .failed:
            notice(
                store.models == .failed ? "Download failed" : "Speech models are needed, 700 MB",
                action: "Download Models"
            ) { store.downloadModels() }
        case .ready:
            EmptyView()
        }
    }

    /// Redrawn ten times a second, only while on screen: the store does not publish levels.
    private var meters: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            VStack(spacing: 6) {
                LevelBar(title: "Microphone", level: store.levels.mic)
                LevelBar(title: "System Audio", level: store.levels.system)
            }
        }
    }

    private func notice(_ text: LocalizedStringKey, action: LocalizedStringKey?, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            if let action {
                Button(action, action: perform)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: - Journal

    @ViewBuilder
    private var journal: some View {
        if store.meetings.isEmpty {
            Text("No meetings yet")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.meetings) { MeetingRow(meeting: $0, store: store) }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let store: MeetingStore
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 8) {
            if meeting.state == .recording {
                Circle().fill(Color.red).frame(width: 6, height: 6)
            }
            Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
            if meeting.systemSilent {
                Image(systemName: "speaker.slash")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.secondary)
                    .help("System sound was not recorded")
            }
            Spacer(minLength: 0)
            status
            if let duration = meeting.duration {
                Text(Self.length(duration))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
    }

    @ViewBuilder
    private var status: some View {
        switch meeting.state {
        case .recording:
            EmptyView()
        case .ready:
            CopyButton { store.copyTranscript(of: meeting) }
            if meeting.audioReady {
                iconButton("square.and.arrow.down", help: "Export") { store.export(meeting) }
            }
        case .waitingForModels:
            label("Waiting for models")
        case .processing:
            label("Transcribing")
        case .failed:
            Button("Retry") { store.retry(meeting) }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
        if meeting.state != .recording, meeting.state != .processing { deleteButton }
    }

    private func iconButton(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The first click arms the button, the second moves the meeting to the Trash.
    @ViewBuilder
    private var deleteButton: some View {
        if confirmingDelete {
            Button("Delete") { store.delete(meeting) }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.red)
        } else {
            iconButton("trash", help: "Delete") {
                confirmingDelete = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmingDelete = false }
            }
        }
    }

    private func label(_ key: LocalizedStringKey) -> some View {
        Text(key).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
    }

    /// `12:34`, or `1:02:03` from an hour up.
    static func length(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

private struct LevelBar: View {
    let title: LocalizedStringKey
    let level: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundStyle(Theme.tertiary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface)
                    Capsule().fill(Color.green)
                        .frame(width: proxy.size.width * CGFloat(min(1, sqrt(level))))
                }
            }
            .frame(height: 4)
        }
    }
}

/// Header badge: a running timer on every tab while recording, the meeting count otherwise.
struct MeetingsBadge: View {
    @ObservedObject var store: MeetingStore

    var body: some View {
        if let recording = store.recording {
            HStack(spacing: 4) {
                Circle().fill(Color.red).frame(width: 6, height: 6)
                TimelineView(.periodic(from: recording.startedAt, by: 1)) { context in
                    Text(MeetingRow.length(context.date.timeIntervalSince(recording.startedAt)))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
            }
        } else if !store.meetings.isEmpty {
            Text("\(store.meetings.count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
    }
}
