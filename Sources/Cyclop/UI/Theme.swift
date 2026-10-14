import SwiftUI

enum Theme {
    static let openAnimation = Animation.spring(response: 0.27, dampingFraction: 0.82)
    static let contentAnimation = Animation.easeOut(duration: 0.16)
    /// Pane switching: the outgoing pane leaves faster than the incoming one
    /// arrives, so the two are never both half-visible for long.
    static let paneAnimation = Animation.easeOut(duration: 0.18)
    static let paneIn = Animation.easeOut(duration: 0.20).delay(0.04)
    static let paneOut = Animation.easeIn(duration: 0.12)

    static let collapsedTopRadius: CGFloat = 6
    static let collapsedBottomRadius: CGFloat = 9
    static let openTopRadius: CGFloat = 12
    static let openBottomRadius: CGFloat = 22

    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)
    static let surface = Color.white.opacity(0.08)
    static let surfaceHover = Color.white.opacity(0.14)
    static let hairline = Color.white.opacity(0.10)
}

/// Flat, focus-free button used for every control in the panel.
struct NotchButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: prominent ? 17 : 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Circle().fill(prominent ? Theme.surfaceHover : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// Tracks hover without triggering layout changes in the parent.
    func onHoverChange(_ action: @escaping (Bool) -> Void) -> some View {
        onHover(perform: action)
    }
}

/// Drawn rather than `NSSwitch`-backed: the panel is a non-activating window
/// that almost never becomes key (that is what keeps hovering it from
/// stealing focus from whatever app was in front), and `NSSwitch` renders its
/// on-state in gray rather than accent blue whenever its window is not key.
/// A plain `Color` fill has no such state to lose.
struct NotchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn ? Color.accentColor : Theme.surfaceHover)
                .frame(width: 28, height: 16)
                .overlay(
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .offset(x: configuration.isOn ? 6 : -6)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: configuration.isOn)
    }
}

/// Drawn rather than a segmented `Picker`: in the never-key panel the system one shows a grey, accent-less selection.
struct NotchSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var disabled: Set<Value> = []
    /// The track's fill; a stronger one where the control sits on a card of `Theme.surface`.
    var track: Color = Theme.surface

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                let off = disabled.contains(option)
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? Color.black : Theme.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 20)
                        .background(Capsule().fill(selected ? Color.white : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(off)
                .opacity(off ? 0.35 : 1)
            }
        }
        .padding(2)
        .background(Capsule().fill(track))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}
