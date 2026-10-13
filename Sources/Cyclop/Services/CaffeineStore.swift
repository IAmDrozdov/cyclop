import AppKit
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// The store's only way to the system, and the one seam its tests use.
@MainActor
protocol PowerPort: AnyObject {
    /// Keeps the Mac from sleeping from idleness. Called only when the state changes.
    func holdIdleSleep()
    func releaseIdleSleep()

    /// A Mac without a lid has no clamshell state at all.
    var hasLid: Bool { get }
    var lidClosed: Bool { get }
    /// Sets or clears the kernel's lid-sleep bit. Setting is idempotent.
    func setLidSleepDisabled(_ disabled: Bool)

    /// The lid moved.
    var onLidChange: (() -> Void)? { get set }
    /// The system may have changed the bit (screen, power source, wake, a
    /// timer) while it is set. The bit cannot be read back, so it is re-sent.
    var onMayHaveChanged: (() -> Void)? { get set }
}

/// The real port: an IOKit assertion against idle system sleep (the display is
/// not held: the screen still turns off and locks on its own schedule), and
/// the root domain's undocumented lid-sleep call. See docs/architecture.md.
@MainActor
final class SystemPowerPort: PowerPort {
    var onLidChange: (() -> Void)?
    var onMayHaveChanged: (() -> Void)?

    private var assertion: IOPMAssertionID = 0

    private let root: io_service_t = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching("IOPMrootDomain")
    )
    private var connect: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    /// `kPMSetClamshellSleepState` from the public IOPMLibDefs.h.
    private static let setClamshellSleepState: UInt32 = 12
    private static let clamshellStateKey = "AppleClamshellState"

    private var reassertTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?

    init() {
        guard hasLid else { return }
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(notifyPort, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(notifyPort, root, kIOGeneralInterest, { refcon, _, _, _ in
            guard let refcon else { return }
            let port = Unmanaged<SystemPowerPort>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { port.lidMoved() }
        }, refcon, &notifier)
    }

    // MARK: - Idle sleep

    func holdIdleSleep() {
        guard assertion == 0 else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Cyclop caffeine" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            assertion = id
        } else {
            NSLog("Cyclop: cannot take the sleep assertion (\(result))")
        }
    }

    func releaseIdleSleep() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }

    // MARK: - Lid

    var hasLid: Bool { lidProperty() != nil }

    var lidClosed: Bool { lidProperty() == true }

    private func lidProperty() -> Bool? {
        guard root != 0,
              let value = IORegistryEntryCreateCFProperty(
                root, Self.clamshellStateKey as CFString, kCFAllocatorDefault, 0
              )?.takeRetainedValue() else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private func lidMoved() {
        onLidChange?()
        onMayHaveChanged?()
    }

    func setLidSleepDisabled(_ disabled: Bool) {
        if connect == 0 {
            guard root != 0,
                  IOServiceOpen(root, mach_task_self_, 0, &connect) == KERN_SUCCESS else {
                NSLog("Cyclop: cannot open the power-management root domain")
                return
            }
        }
        var flag: UInt64 = disabled ? 1 : 0
        let result = IOConnectCallScalarMethod(
            connect, Self.setClamshellSleepState, &flag, 1, nil, nil
        )
        if result != KERN_SUCCESS { NSLog("Cyclop: lid-sleep call refused (\(result))") }
        if disabled { watchForChanges() } else { stopWatching() }
    }

    /// Re-sending triggers, only while the bit is set.
    private func watchForChanges() {
        guard reassertTimer == nil else { return }
        reassertTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onMayHaveChanged?() }
        }
        observers = [
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.onMayHaveChanged?() } },
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.onMayHaveChanged?() } },
        ]
        // Power-source changes have no Foundation notification.
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let port = Unmanaged<SystemPowerPort>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { port.onMayHaveChanged?() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }
    }

    private func stopWatching() {
        reassertTimer?.invalidate()
        reassertTimer = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        powerSource = nil
    }
}

/// Keeps the Mac awake: a caffeine session, indefinite or until a deadline,
/// and lid-closed mode, a standing switch independent of sessions.
///
/// Two rules decide everything and nothing else does. The idle-sleep hold
/// exists exactly while a session runs, or the mode is on with the lid closed.
/// The lid-sleep bit is set exactly while the mode is on and background work
/// is running.
///
/// Knows nothing of the config file: saved values come in at creation and go
/// back out through callbacks. Publishes changes of state, not the countdown:
/// the view draws that from the deadline.
@MainActor
final class CaffeineStore: ObservableObject {
    enum Session: Equatable {
        case none
        case indefinite
        case timed(until: Date)
    }

    /// The wheel's range: hours 0–23, minutes in steps of 5.
    nonisolated static let minuteStep = 5
    nonisolated static let maxMinutes = 23 * 60 + 55
    nonisolated static let defaultMinutes = 60

    /// The nearest value on the wheel: the config file is edited by hand.
    nonisolated static func onWheel(_ minutes: Int) -> Int {
        let clamped = min(max(minutes, 0), maxMinutes)
        return Int((Double(clamped) / Double(minuteStep)).rounded()) * minuteStep
    }

    @Published private(set) var session: Session = .none

    /// The duration on the wheel. Handed back to the owner on every change.
    @Published var minutes: Int {
        didSet {
            let fixed = Self.onWheel(minutes)
            if fixed != minutes { minutes = fixed; onMinutesChange(fixed); return }
            guard minutes != oldValue else { return }
            onMinutesChange(minutes)
        }
    }

    /// Lid-closed mode: a standing switch, handed back to the owner on change.
    @Published private(set) var lidClosedMode: Bool
    @Published private(set) var lidIsClosed: Bool
    let hasLid: Bool

    var isRunning: Bool { session != .none }

    private let port: PowerPort
    private let onMinutesChange: (Int) -> Void
    private let onLidClosedModeChange: (Bool) -> Void
    private var holding = false
    private var bitSet = false
    private var backgroundRunning = false
    private var expiry: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(
        port: PowerPort = SystemPowerPort(),
        minutes: Int = CaffeineStore.defaultMinutes,
        lidClosedMode: Bool = false,
        onMinutesChange: @escaping (Int) -> Void = { _ in },
        onLidClosedModeChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.port = port
        self.minutes = Self.onWheel(minutes)
        self.hasLid = port.hasLid
        self.lidClosedMode = lidClosedMode && port.hasLid
        self.lidIsClosed = port.hasLid && port.lidClosed
        self.onMinutesChange = onMinutesChange
        self.onLidClosedModeChange = onLidClosedModeChange
        port.onLidChange = { [weak self] in self?.lidMoved() }
        port.onMayHaveChanged = { [weak self] in self?.resendBit() }
    }

    // MARK: - Sessions

    func startIndefinite() {
        set(.indefinite)
    }

    /// For the duration on the wheel. Zero is no session at all.
    func startTimed(now: Date = Date()) {
        guard minutes > 0 else { return }
        set(.timed(until: now.addingTimeInterval(TimeInterval(minutes * 60))))
    }

    func stop() {
        set(.none)
    }

    /// Ends a timed session whose deadline has passed. A deadline that fell
    /// during sleep is caught at the first call after wake.
    func expireIfDue(now: Date = Date()) {
        if case .timed(let until) = session, until <= now { set(.none) }
    }

    private func set(_ new: Session) {
        guard new != session else { return }
        session = new
        syncHold()
        expiry?.invalidate()
        expiry = nil
        if case .timed(let until) = new {
            let timer = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.expireIfDue(now: until) }
            }
            RunLoop.main.add(timer, forMode: .common)
            expiry = timer
        }
    }

    // MARK: - Lid-closed mode

    func setLidClosedMode(_ on: Bool) {
        guard hasLid, on != lidClosedMode else { return }
        lidClosedMode = on
        onLidClosedModeChange(on)
        syncBit()
        syncHold()
    }

    private func lidMoved() {
        lidIsClosed = port.lidClosed
        syncHold()
    }

    private func resendBit() {
        if bitWanted { port.setLidSleepDisabled(true) }
    }

    // MARK: - The two rules

    private var holdWanted: Bool {
        isRunning || (backgroundRunning && lidClosedMode && lidIsClosed)
    }

    private var bitWanted: Bool {
        hasLid && lidClosedMode && backgroundRunning
    }

    private func syncHold() {
        let wanted = holdWanted
        guard wanted != holding else { return }
        holding = wanted
        if wanted { port.holdIdleSleep() } else { port.releaseIdleSleep() }
    }

    /// Sets the bit when wanted; clears it only if this app set it, so a bit
    /// somebody else owns is not cleared on the way past.
    private func syncBit() {
        if bitWanted {
            port.setLidSleepDisabled(true)
            bitSet = true
        } else if bitSet {
            port.setLidSleepDisabled(false)
            bitSet = false
        }
    }

    // MARK: - Background work

    /// Sends the value the switch calls for, on or off: a bit left by a crash
    /// is cleared here, since it cannot be read back.
    func beginBackground() {
        guard !backgroundRunning else { return }
        backgroundRunning = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.expireIfDue() }
        }
        if hasLid {
            port.setLidSleepDisabled(bitWanted)
            bitSet = bitWanted
            lidIsClosed = port.lidClosed
        }
        syncHold()
    }

    /// Ends the session, drops the hold and clears the bit. The saved switch stays.
    func endBackground() {
        backgroundRunning = false
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        stop()
        syncBit()
        syncHold()
    }
}
