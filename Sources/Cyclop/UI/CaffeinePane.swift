import SwiftUI

/// Idle: one button for no end, and a wheel with Start for a chosen time.
/// During a session: the time left, or the sign for no end, and Stop.
struct CaffeinePane: View {
    @ObservedObject var caffeine: CaffeineStore

    var body: some View {
        VStack(spacing: 10) {
            if caffeine.isRunning {
                running
            } else {
                idle
            }
            if caffeine.hasLid { lidSwitch }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 2)
        // A deadline passed while the panel was closed: settle it on arrival.
        .onAppear { caffeine.expireIfDue() }
    }

    // MARK: - Idle

    private var idle: some View {
        HStack(spacing: 28) {
            Button {
                caffeine.startIndefinite()
            } label: {
                Text("Stay Awake Indefinitely")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .background(Capsule().fill(Theme.surfaceHover))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Rectangle().fill(Theme.hairline).frame(width: 1, height: 96)

            HStack(spacing: 14) {
                wheel
                Button {
                    caffeine.startTimed()
                } label: {
                    Text("Start")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(Capsule().fill(Color.accentColor))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(caffeine.minutes == 0)
                .opacity(caffeine.minutes == 0 ? 0.35 : 1)
            }
        }
    }

    private var wheel: some View {
        HStack(spacing: 6) {
            WheelColumn(
                values: Array(0...23),
                selection: Binding(
                    get: { caffeine.minutes / 60 },
                    set: { caffeine.minutes = $0 * 60 + caffeine.minutes % 60 }
                ),
                unit: "h"
            )
            WheelColumn(
                values: Array(stride(from: 0, to: 60, by: CaffeineStore.minuteStep)),
                selection: Binding(
                    get: { caffeine.minutes % 60 },
                    set: { caffeine.minutes = caffeine.minutes / 60 * 60 + $0 }
                ),
                unit: "min"
            )
        }
    }

    private var lidSwitch: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { caffeine.lidClosedMode },
                set: { caffeine.setLidClosedMode($0) }
            ))
            .toggleStyle(NotchToggleStyle())
            .labelsHidden()
            Text("Stay Awake with the Lid Closed")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
        }
    }

    // MARK: - Running

    private var running: some View {
        VStack(spacing: 14) {
            TimeLeft(session: caffeine.session)
                .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
            Button {
                caffeine.stop()
            } label: {
                Text("Stop")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 30)
                    .background(Capsule().fill(Theme.surfaceHover))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

/// The header's badge, observing the store itself.
struct CaffeineBadge: View {
    @ObservedObject var caffeine: CaffeineStore

    var body: some View {
        if caffeine.isRunning {
            TimeLeft(session: caffeine.session)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.secondary)
        }
    }
}

/// The time left drawn from the deadline once a second, so the store does not
/// publish the countdown. The sign for no end for an indefinite session.
private struct TimeLeft: View {
    let session: CaffeineStore.Session

    var body: some View {
        switch session {
        case .none:
            EmptyView()
        case .indefinite:
            Text("∞")
        case .timed(let until):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.format(until.timeIntervalSince(context.date)))
            }
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

/// One column of the wheel. SwiftUI has no wheel picker on macOS, so this is a
/// scroll view that snaps to a row, with the middle row marked.
private struct WheelColumn: View {
    let values: [Int]
    @Binding var selection: Int
    let unit: String

    private let rowHeight: CGFloat = 28
    private let rows = 3

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(values, id: \.self) { value in
                        Text(String(format: "%02d", value))
                            .font(.system(size: 20, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(value == selection ? Color.white : Theme.tertiary)
                            .frame(height: rowHeight)
                            .frame(maxWidth: .infinity)
                            .id(value)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.vertical, rowHeight * CGFloat(rows / 2), for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: Binding<Int?>(
                get: { selection },
                set: { newValue in if let newValue { selection = newValue } }
            ), anchor: .center)
            .frame(width: 44, height: rowHeight * CGFloat(rows))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.surface)
                    .frame(height: rowHeight)
            )
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.3),
                        .init(color: .black, location: 0.7),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )

            Text(LocalizedStringKey(unit))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
    }
}
