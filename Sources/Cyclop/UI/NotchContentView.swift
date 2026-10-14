import AppKit
import SwiftUI

struct NotchContentView: View {
    @ObservedObject var vm: NotchViewModel
    /// This screen's share of the panel. Everything the pointer decides is
    /// here; everything shown is in `vm`, the same on every display.
    @ObservedObject var panel: PanelState

    /// The rail icon being pressed, shared by both rails so it can cross over.
    @State private var hold: RailHold?
    /// Each rail's icon column in `Rail.space`, keyed by whether it is the right one.
    @State private var railFrames: [Bool: CGRect] = [:]

    private var isOpen: Bool { panel.isActive }
    private var size: CGSize { panel.bodySize }
    private var topRadius: CGFloat { isOpen ? Theme.openTopRadius : Theme.collapsedTopRadius }

    /// Whether the shape is painted at all.
    ///
    /// Folded over a real notch there is nothing to paint: the notch is a hole,
    /// and a hole is already black. The filled shape on top of it is invisible
    /// — but only for as long as what is behind it stays black, and that is not
    /// something the panel gets to assume. The window is `.stationary` and
    /// joins every space, so it stands still while the desktop moves: in
    /// Mission Control and mid-swipe between spaces the desktop shrinks away
    /// and the "notch" is left hanging in the air as a black rectangle over the
    /// Spaces bar. It reads as a second, squarer notch, which is exactly what
    /// it is — a picture of a hole with no hole behind it.
    ///
    /// A drawn notch is the opposite case: there the shape *is* the notch, and
    /// it has to be visible wherever the panel stands. So the rule is narrow —
    /// only the display that has a real cutout, and only while the panel has
    /// nothing of its own to show.
    ///
    /// "Nothing of its own" is asked of the body rather than of `isOpen`, and
    /// the difference is not stylistic. On a hole the body is the notch exactly
    /// when there is nothing to show — folded, `bodySize` is `collapsedSize`,
    /// and on a hole that is the notch itself —
    /// so any future state that grows the folded strip paints itself without
    /// anyone remembering to come back here. Keyed on `isOpen`, the next such
    /// state would draw its text onto a transparent background: white letters
    /// standing on the desktop with nothing behind them.
    private var paintsShape: Bool {
        !panel.geometry.isPhysical || size != panel.geometry.notchSize
    }

    var body: some View {
        // The shape is wider than the body by `topRadius` on each side: that
        // slack is where the concave shoulders live, so it must not be clipped.
        ZStack(alignment: .top) {
            NotchShape(
                topRadius: topRadius,
                bottomRadius: isOpen ? Theme.openBottomRadius : Theme.collapsedBottomRadius
            )
            .fill(paintsShape ? Color.black : Color.clear)
            .frame(width: size.width + 2 * topRadius, height: size.height)
            .shadow(color: .black.opacity(isOpen ? 0.5 : 0), radius: 18, y: 8)

            VStack(spacing: 0) {
                header
                if isOpen {
                    content
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
        }
        .frame(width: size.width + 2 * topRadius, height: size.height, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Theme.openAnimation, value: isOpen)
        .animation(Theme.paneAnimation, value: vm.tab)
        .animation(Theme.contentAnimation, value: panel.standardBodyHeight)
    }

    // MARK: - Header
    //
    // This strip sits directly on top of the menu bar. Menu bar utilities such
    // as Ice watch for clicks there with a global event monitor — a passive
    // observer that sees the click no matter which window consumes it — so
    // clicking here toggles them as a side effect. Nothing interactive goes in
    // this row; the tab switcher lives in the rail below.

    private var header: some View {
        HStack(spacing: 0) {
            if isOpen {
                Text(vm.tab.title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.tertiary)
                    .padding(.leading, 16)
                    .id(vm.tab)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            Color.clear.frame(width: panel.geometry.notchSize.width, height: 1)
            Spacer(minLength: 0)
            if isOpen {
                trailing
                    .padding(.trailing, 16)
                    .transition(.opacity)
            }
        }
        .frame(height: panel.geometry.notchSize.height)
    }

    @ViewBuilder
    private var trailing: some View {
        // A running recording shows its timer on every tab.
        if vm.meetings.recording != nil {
            MeetingsBadge(store: vm.meetings)
        } else {
            tabBadge
        }
    }

    @ViewBuilder
    private var tabBadge: some View {
        switch vm.tab {
        case .claude:
            counter(vm.claude.waitingCount)
        case .shelf:
            counter(vm.shelf.items.count)
        case .clipboard:
            counter(vm.clipboard.items.count)
        case .snippets:
            counter(vm.snippets.items.count)
        case .translate:
            // Nothing: the columns name both languages already, and the strip
            // is the one part of the panel worth not spending on a repeat.
            EmptyView()
        case .caffeine:
            CaffeineBadge(caffeine: vm.caffeine)
        case .currency:
            CurrencyRateDate(currencies: vm.currencies)
        case .teleprompter:
            EmptyView()
        case .meetings:
            MeetingsBadge(store: vm.meetings)
        case .settings:
            EmptyView()
        }
    }

    @ViewBuilder
    private func counter(_ value: Int) -> some View {
        if value > 0 {
            Text("\(value)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
    }

    // MARK: - Body

    private var content: some View {
        HStack(spacing: 14) {
            Rail(vm: vm, panel: panel, tabs: vm.leftRail, isRight: false, hold: $hold, frames: $railFrames)
            panes
            Rail(vm: vm, panel: panel, tabs: vm.rightRail, isRight: true, hold: $hold, frames: $railFrames)
        }
        .coordinateSpace(name: Rail.space)
        .padding(.horizontal, 14)
        // The body's height is measured from this same number, so the two
        // cannot drift apart into a rail that does not fit.
        .padding(.bottom, NotchGeometry.bodyBottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var panes: some View {
        // Content is replaced in place — no travel. The rail is vertical and
        // the panes are unrelated, so a direction would only be decoration.
        ZStack {
            pane
                .id(vm.tab)
                .transition(.asymmetric(
                    insertion: .opacity
                        .combined(with: .scale(scale: 0.97))
                        .animation(Theme.paneIn),
                    removal: .opacity
                        .combined(with: .scale(scale: 1.02))
                        .animation(Theme.paneOut)
                ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var pane: some View {
        switch vm.tab {
        case .claude:
            ClaudePane(store: vm.claude, privacy: vm.privacy, wantsKeyboard: $panel.wantsKeyboard, showSettings: { vm.settingsPage = .tabs; vm.tab = .settings })
        case .shelf:
            ShelfPane(shelf: vm.shelf, isTargeted: panel.isDropTargeted)
        case .clipboard:
            ClipboardPane(clipboard: vm.clipboard, privacy: vm.privacy)
        case .snippets:
            SnippetsPane(snippets: vm.snippets, privacy: vm.privacy, wantsKeyboard: $panel.wantsKeyboard)
        case .translate:
            TranslatePane(translator: vm.translator, wantsKeyboard: $panel.wantsKeyboard)
        case .caffeine:
            CaffeinePane(caffeine: vm.caffeine)
        case .currency:
            CurrencyPane(currencies: vm.currencies, wantsKeyboard: $panel.wantsKeyboard)
        case .teleprompter:
            TeleprompterPane(prompter: vm.teleprompter, wantsKeyboard: $panel.wantsKeyboard)
        case .meetings:
            MeetingsPane(store: vm.meetings)
        case .settings:
            SettingsPane(vm: vm, shelf: vm.shelf, screenshots: vm.screenshotFolder)
        }
    }
}

/// Rate fetches must not redraw the whole panel on every keystroke in the
/// amount fields, and the view model does not forward keystroke-driven
/// stores, so the date badge observes the store on its own.
private struct CurrencyRateDate: View {
    @ObservedObject var currencies: CurrencyStore

    var body: some View {
        if let date = currencies.rateDate {
            Text(date)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
    }
}

/// A rail icon held down: a click until it is lifted, a drag after.
private struct RailHold: Equatable {
    let tab: NotchViewModel.Tab
    var lifted = false
    /// The pointer wandered before the icon lifted: no lift any more.
    var moved = false
}

/// Tab switcher.
///
/// Hovering switches tabs, but only after the pointer has stopped: a pointer
/// crossing the rail on its way somewhere else is gone in a few dozen
/// milliseconds, while one that came to choose stays put. The same dwell
/// threshold is what separates "the mouse was flung across the top of the
/// screen" from "the mouse came to the notch" in `PointerWatcher`.
///
/// Holding an icon for `liftDelay`, or pressing it hard on a Force Touch
/// trackpad, lifts it; dragging then moves it along this rail or onto the
/// other one. The press is the rail's gesture, not the icon's: an icon moved
/// to the other rail is a new view, and a gesture on it would end there.
private struct Rail: View {
    static let space = "rails"

    @ObservedObject var vm: NotchViewModel
    @ObservedObject var panel: PanelState
    /// Which icons this rail carries — there are two rails, one per side.
    let tabs: [NotchViewModel.Tab]
    let isRight: Bool
    @Binding var hold: RailHold?
    @Binding var frames: [Bool: CGRect]

    @State private var hovered: NotchViewModel.Tab?
    @State private var liftTask: Task<Void, Never>?
    @State private var pressureMonitor: Any?
    @GestureState private var pressing = false

    /// Long enough to swallow a pass-through, short enough that a deliberate
    /// hover still feels like it answered instantly.
    private let dwell = Duration.milliseconds(150)
    private let liftDelay = Duration.milliseconds(400)
    /// How far a press may wander and still be a click.
    private let slop: CGFloat = 4

    private var iconSize: CGFloat { vm.railIconSize }
    private var width: CGFloat { max(30, iconSize + 6) }
    private var step: CGFloat { iconSize + NotchGeometry.railSpacing }

    var body: some View {
        VStack(spacing: NotchGeometry.railSpacing) {
            ForEach(tabs) { tab in
                icon(tab)
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[isRight] = $0 }
        .gesture(press)
        // Centred in the height an ordinary tab has, then that block pinned to
        // the top of whatever height this tab actually got. On a normal
        // tab the two are the same and nothing moves; on the teleprompter the
        // extra height goes to the script below, and the icons stay put.
        .frame(height: panel.railContentHeight, alignment: .center)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(Theme.contentAnimation, value: hovered)
        .animation(Theme.contentAnimation, value: hold)
        // A gesture cut short never reaches `onEnded`, but its state still
        // resets; a panel closing under it takes the rail away instead.
        .onChange(of: pressing) { _, now in
            if !now { DispatchQueue.main.async { endHold() } }
        }
        .onDisappear { endHold() }
        // An icon that left for the other rail never reports the pointer leaving it.
        .onChange(of: tabs) { _, now in
            if let hovered, !now.contains(hovered) { self.hovered = nil }
        }
        // Moving to another icon cancels the pending switch along with the
        // task, so only the icon actually rested on ever wins.
        .task(id: hovered) {
            guard let hovered, hovered != vm.tab, hold == nil else { return }
            try? await Task.sleep(for: dwell)
            guard !Task.isCancelled, hold == nil else { return }
            panel.select(hovered)
        }
    }

    private func icon(_ tab: NotchViewModel.Tab) -> some View {
        let lifted = hold?.tab == tab && hold?.lifted == true
        return Image(systemName: tab.symbol)
            .font(.system(size: iconSize * 0.5, weight: .medium))
            .frame(width: width, height: iconSize)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(lifted ? Theme.surfaceHover : fill(for: tab))
            )
            .foregroundStyle(tint(for: tab))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            // A render-time transform. Growing the frame instead would re-lay
            // out the rail on every hover, and layout that runs on pointer
            // movement is exactly the kind that shows up as a stutter.
            .scaleEffect(lifted ? 1.2 : hovered == tab ? 1.15 : 1)
            .shadow(color: .black.opacity(lifted ? 0.6 : 0), radius: 6, y: 2)
            .zIndex(lifted ? 1 : 0)
            .onHover { inside in
                if inside {
                    hovered = tab
                } else if hovered == tab {
                    hovered = nil
                }
            }
            .accessibilityElement()
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { panel.select(tab) }
    }

    // MARK: - Press, lift, drag

    private var press: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .updating($pressing) { _, state, _ in state = true }
            .onChanged { value in
                guard var current = hold else {
                    if let tab = tab(at: value.startLocation) { begin(tab) }
                    return
                }
                if current.lifted {
                    drop(current.tab, at: value.location)
                } else if !current.moved, hypot(value.translation.width, value.translation.height) > slop {
                    current.moved = true
                    hold = current
                    stopWaiting()
                }
            }
            // Released on the icon it pressed, short of a lift, is a click,
            // however much the pointer wobbled on the way.
            .onEnded { value in
                if let current = hold, !current.lifted, tab(at: value.location) == current.tab {
                    panel.select(current.tab)
                }
                endHold()
            }
    }

    /// The icon under a point of this rail, gaps included.
    private func tab(at point: CGPoint) -> NotchViewModel.Tab? {
        guard let frame = frames[isRight], frame.insetBy(dx: -slop, dy: -slop).contains(point) else { return nil }
        let index = Int(((point.y - frame.minY) / step).rounded(.down))
        return tabs.indices.contains(index) ? tabs[index] : nil
    }

    private func begin(_ tab: NotchViewModel.Tab) {
        hold = RailHold(tab: tab)
        liftTask = Task {
            try? await Task.sleep(for: liftDelay)
            guard !Task.isCancelled else { return }
            lift()
        }
        // Force Touch: the second stage of a press is a deliberate hard click.
        pressureMonitor = NSEvent.addLocalMonitorForEvents(matching: .pressure) { event in
            if event.stage >= 2 { MainActor.assumeIsolated { lift() } }
            return event
        }
    }

    private func lift() {
        guard var current = hold, !current.lifted, !current.moved else { return }
        current.lifted = true
        hold = current
        stopWaiting()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// Puts the lifted tab into the slot under the pointer, on whichever rail
    /// is nearer. Slots are counted from the rail's centre, which stays put
    /// as the rail gains or loses the icon: counted from its top, the slot
    /// would shift by half an icon the moment the tab arrived.
    private func drop(_ tab: NotchViewModel.Tab, at point: CGPoint) {
        var toRight = isRight
        if let left = frames[false], let right = frames[true] {
            toRight = abs(point.x - right.midX) < abs(point.x - left.midX)
        }
        guard let frame = frames[toRight] else { return }
        let others = (toRight ? vm.rightRail : vm.leftRail).filter { $0 != tab }
        let slots = CGFloat(others.count + 1)
        let top = frame.midY - (slots * step - NotchGeometry.railSpacing) / 2
        let slot = min(max(Int(((point.y - top) / step).rounded(.down)), 0), others.count)
        let before = slot < others.count ? others[slot] : nil
        withAnimation(Theme.contentAnimation) {
            vm.moveTab(tab, toRight: toRight, before: before)
        }
    }

    private func stopWaiting() {
        liftTask?.cancel()
        liftTask = nil
        if let pressureMonitor { NSEvent.removeMonitor(pressureMonitor) }
        pressureMonitor = nil
    }

    private func endHold() {
        stopWaiting()
        if hold != nil { hold = nil }
    }
    /// A running caffeine session tints its icon on every tab.
    private func tint(for tab: NotchViewModel.Tab) -> Color {
        if tab == .caffeine, vm.caffeine.isRunning { return .accentColor }
        if tab == .meetings, vm.meetings.recording != nil { return .red }
        return vm.tab == tab ? Color.white : Theme.tertiary
    }

    private func fill(for tab: NotchViewModel.Tab) -> Color {
        if vm.tab == tab { return Theme.surfaceHover }
        return hovered == tab ? Theme.surface : .clear
    }
}
