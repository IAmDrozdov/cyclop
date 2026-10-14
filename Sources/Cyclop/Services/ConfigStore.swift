import AppKit

/// Everything about Cyclop that makes sense on somebody else's Mac, in one
/// file next to `snippets.json` (#67).
///
/// Before this, the same handful of settings each kept their own place and
/// their own copy of "and what if the key isn't there yet": `showOnAllDisplays`
/// in `NotchGeometry`, `saveClipboardImages` in `NotchViewModel`, the privacy
/// sections in `PrivacyMode`, the teleprompter's speed and font size in
/// `TeleprompterStore`, and, freshest, the tab switches from #80. Harmless at
/// four; every new setting was the fifth spelling of the same question.
///
/// **What comes here.** What has meaning on another Mac. Shelf paths (content,
/// not configuration) stay in `UserDefaults` — see #67 for the rule.
///
/// **Migration.** No file yet → built once from the old `UserDefaults` keys
/// and written. The old keys are then left alone: rolling back to a build
/// before this one loses a few switches rather than this app carrying two
/// sources of truth for one release (decided in #67).
@MainActor
final class ConfigStore: ObservableObject {
    private struct Teleprompter: Codable, Equatable {
        var speed: Double = 1
        var fontSize: Double = 30

        init() {}

        /// Same reason as `File.init(from:)`: a hand edit may keep one key.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Teleprompter()
            speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
            fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        }
    }

    /// Depth in points, dwell in milliseconds: see `NotchGeometry.hoverRect(depth:)`.
    private struct Notch: Codable, Equatable {
        var depth: Double = 8
        var dwell: Double = 120

        init() {}

        /// Same reason as `File.init(from:)`: a hand edit may keep one key.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Notch()
            depth = try c.decodeIfPresent(Double.self, forKey: .depth) ?? d.depth
            dwell = try c.decodeIfPresent(Double.self, forKey: .dwell) ?? d.dwell
        }
    }

    /// The last duration on the Caffeine wheel, in minutes.
    private struct Caffeine: Codable, Equatable {
        var minutes: Int = CaffeineStore.defaultMinutes
        var lidClosed = false

        init() {}

        /// Same reason as `File.init(from:)`: a hand edit may keep one key.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Caffeine()
            minutes = try c.decodeIfPresent(Int.self, forKey: .minutes) ?? d.minutes
            lidClosed = try c.decodeIfPresent(Bool.self, forKey: .lidClosed) ?? d.lidClosed
        }
    }

    /// Rail order by `Tab.rawValue`. Empty on both sides means the default
    /// order; `RailOrder.normalized` makes any saved one whole.
    struct Rails: Codable, Equatable {
        var left: [String] = []
        var right: [String] = []

        init(left: [String] = [], right: [String] = []) {
            self.left = left
            self.right = right
        }

        /// Same reason as `File.init(from:)`: a hand edit may keep one key.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            left = try c.decodeIfPresent([String].self, forKey: .left) ?? []
            right = try c.decodeIfPresent([String].self, forKey: .right) ?? []
        }
    }

    /// What a plan card starts from, as `PlanChoice`'s raw values. One a newer or older build does not know reads as the default.
    struct PlanApproval: Codable, Equatable {
        var context = "clear"
        var model = "sonnet"
        var effort = "medium"
        var mode = "bypassPermissions"

        init() {}

        /// Same reason as `File.init(from:)`: a hand edit may keep one key.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = PlanApproval()
            context = try c.decodeIfPresent(String.self, forKey: .context) ?? d.context
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
            effort = try c.decodeIfPresent(String.self, forKey: .effort) ?? d.effort
            mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? d.mode
        }
    }

    private struct File: Codable, Equatable {
        var showOnAllDisplays = true
        var saveClipboardImages = true
        var privacy: [String] = []
        var teleprompter = Teleprompter()
        var hiddenTabs: [String] = []
        var fullSizeDrawnNotch = false
        var notch = Notch()
        var caffeine = Caffeine()
        var openPanelForRequests = true
        var rails = Rails()
        var railIconSize: Double = 24
        var planApproval = PlanApproval()

        init() {}

        /// Every key optional, falling back to the default above. The
        /// synthesized decoder treats a key it does not find as a broken
        /// file, so the first setting added after release would have turned
        /// every existing `config.json` read-only in one go — the file written
        /// by the previous version simply does not have it.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = File()
            showOnAllDisplays = try c.decodeIfPresent(Bool.self, forKey: .showOnAllDisplays) ?? d.showOnAllDisplays
            saveClipboardImages = try c.decodeIfPresent(Bool.self, forKey: .saveClipboardImages) ?? d.saveClipboardImages
            privacy = try c.decodeIfPresent([String].self, forKey: .privacy) ?? d.privacy
            teleprompter = try c.decodeIfPresent(Teleprompter.self, forKey: .teleprompter) ?? d.teleprompter
            hiddenTabs = try c.decodeIfPresent([String].self, forKey: .hiddenTabs) ?? d.hiddenTabs
            fullSizeDrawnNotch = try c.decodeIfPresent(Bool.self, forKey: .fullSizeDrawnNotch) ?? d.fullSizeDrawnNotch
            notch = try c.decodeIfPresent(Notch.self, forKey: .notch) ?? d.notch
            caffeine = try c.decodeIfPresent(Caffeine.self, forKey: .caffeine) ?? d.caffeine
            openPanelForRequests = try c.decodeIfPresent(Bool.self, forKey: .openPanelForRequests) ?? d.openPanelForRequests
            rails = try c.decodeIfPresent(Rails.self, forKey: .rails) ?? d.rails
            railIconSize = try c.decodeIfPresent(Double.self, forKey: .railIconSize) ?? d.railIconSize
            planApproval = try c.decodeIfPresent(PlanApproval.self, forKey: .planApproval) ?? d.planApproval
        }
    }

    static let shared = ConfigStore()

    /// `~/Library/Application Support/Cyclop/config.json`.
    static let file = Support.file("config.json")

    /// True when the file exists but cannot be parsed — same meaning and the
    /// same consequence as `SnippetStore.fileBroken` (#7): reading stays
    /// honest, and writing stops rather than paving over a hand edit gone
    /// wrong.
    @Published private(set) var fileBroken = false

    private var value: File

    /// A slider's value is in `value` but not on disk yet: see `flush()`.
    private var isDirty = false

    private init() {
        if let data = try? Data(contentsOf: Self.file) {
            do {
                value = try JSONDecoder().decode(File.self, from: data)
            } catch {
                value = File()
                fileBroken = true
                NSLog("Cyclop: config.json is not readable: \(error.localizedDescription)")
            }
        } else {
            // Nothing on disk yet, so nothing to protect — assembled from
            // whatever the old keys already say and written straight away.
            value = Self.migrated()
            write(value)
        }
    }

    // MARK: - Settings

    /// Persisted switch for every display past the first. Defaults to on: the
    /// panel is meant to be wherever the pointer is, so this is the way to
    /// pull it back to one screen, not the way to ask for the rest.
    var showOnAllDisplays: Bool {
        get { value.showOnAllDisplays }
        set { value.showOnAllDisplays = newValue; persist() }
    }

    /// Brings back the notch drawn the full height of the menu bar on displays
    /// without a cutout. Off by default: see `NotchGeometry.collapsedDepth`.
    var fullSizeDrawnNotch: Bool {
        get { value.fullSizeDrawnNotch }
        set { value.fullSizeDrawnNotch = newValue; persist() }
    }

    /// How far into a physical notch the pointer has to be, in points. Clamped
    /// on the way out: the file is edited by hand. Set by a slider, so it is
    /// written by `flush()` and not on every step of a drag.
    var notchDepth: Double {
        get { value.notch.depth.clamped(to: NotchGeometry.depthRange) }
        set { value.notch.depth = newValue; isDirty = true }
    }

    /// The pause before a physical notch opens, in milliseconds. Written by `flush()`.
    var notchDwell: Double {
        get { value.notch.dwell.clamped(to: NotchGeometry.dwellRange) }
        set { value.notch.dwell = newValue; isDirty = true }
    }

    /// Off switch for people who copy images all day and do not want them
    /// kept. Defaults to on: the feature is the reason the folder exists.
    var saveClipboardImages: Bool {
        get { value.saveClipboardImages }
        set { value.saveClipboardImages = newValue; persist() }
    }

    /// Raw `PrivacyMode.Section` values. Kept as strings here rather than that
    /// type so this store does not need to know about it — the same reason
    /// `hiddenTabs` below is `[String]` and not `[NotchViewModel.Tab]`.
    var privacy: [String] {
        get { value.privacy }
        set { value.privacy = newValue; persist() }
    }

    /// Set by a slider: written by `flush()`.
    var teleprompterSpeed: Double {
        get { value.teleprompter.speed }
        set { value.teleprompter.speed = newValue; isDirty = true }
    }

    var teleprompterFontSize: Double {
        get { value.teleprompter.fontSize }
        set { value.teleprompter.fontSize = newValue; persist() }
    }

    /// The Caffeine wheel's last duration, written by `flush()` when the tab is
    /// left and on quit: a fling turns the wheel through many rows. Read as the nearest value on the
    /// wheel: the file is edited by hand.
    var caffeineMinutes: Int {
        get { CaffeineStore.onWheel(value.caffeine.minutes) }
        set { value.caffeine.minutes = newValue; isDirty = true }
    }

    /// Lid-closed mode of the Caffeine tab: the switch survives a relaunch.
    var caffeineLidClosed: Bool {
        get { value.caffeine.lidClosed }
        set { value.caffeine.lidClosed = newValue; persist() }
    }

    /// Whether the panel slides out by itself for a Claude request. On by default; older files lack the key.
    var openPanelForRequests: Bool {
        get { value.openPanelForRequests }
        set { value.openPanelForRequests = newValue; persist() }
    }

    /// Tabs switched off in Settings (#80), by `Tab.rawValue`. Kept as the set
    /// of what is off rather than what is on, so a tab added in a later
    /// version shows up for everyone instead of arriving hidden.
    var hiddenTabs: [String] {
        get { value.hiddenTabs }
        set { value.hiddenTabs = newValue; persist() }
    }

    /// Rail order the owner arranged by dragging icons.
    var rails: Rails {
        get { value.rails }
        set { value.rails = newValue; persist() }
    }

    /// Set by a slider: written by `flush()`. Read clamped: the file is edited by hand.
    var railIconSize: Double {
        get { min(max(value.railIconSize, NotchGeometry.railIconSizeRange.lowerBound), NotchGeometry.railIconSizeRange.upperBound) }
        set { value.railIconSize = newValue; isDirty = true }
    }

    /// The Claude tab's plan card starts from these.
    var planApproval: PlanApproval {
        get { value.planApproval }
        set { value.planApproval = newValue; persist() }
    }

    // MARK: - Migration

    /// Reads the five places these settings used to live. Each guard mirrors
    /// exactly what that setting's own `object(forKey:) != nil` check used to
    /// do, so a Mac with none of these keys set gets the same defaults as
    /// before and a Mac with some of them set keeps exactly those.
    private static func migrated() -> File {
        let defaults = UserDefaults.standard
        var file = File()
        if defaults.object(forKey: "showOnAllDisplays") != nil {
            file.showOnAllDisplays = defaults.bool(forKey: "showOnAllDisplays")
        }
        if defaults.object(forKey: "saveClipboardImages") != nil {
            file.saveClipboardImages = defaults.bool(forKey: "saveClipboardImages")
        }
        if let sections = defaults.array(forKey: "privacyMode.sections") as? [String] {
            file.privacy = sections
        } else if defaults.bool(forKey: "privacyMode") {
            // The legacy switch covered everything or nothing — see
            // `PrivacyMode.init` before this store existed.
            file.privacy = ["clipboard", "snippets"]
        }
        if let speed = defaults.object(forKey: "teleprompter.speed") as? Double {
            file.teleprompter.speed = speed
        }
        if let fontSize = defaults.object(forKey: "teleprompter.fontSize") as? Double {
            file.teleprompter.fontSize = fontSize
        }
        if let hidden = defaults.stringArray(forKey: "hiddenTabs") {
            file.hiddenTabs = hidden
        }
        return file
    }

    // MARK: - Storage

    private func persist() {
        isDirty = false
        write(value)
    }

    /// Writes what the sliders left unwritten. Called when a slider is let go
    /// and on quit: a drag changes the value some sixty times a second.
    func flush() {
        guard isDirty else { return }
        persist()
    }

    /// Pretty-printed, and slashes left alone — same reason as
    /// `snippets.json`: this file is meant to be opened, edited by hand, and
    /// handed to somebody else's Mac.
    private func write(_ file: File) {
        guard !fileBroken else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            try encoder.encode(file).write(to: Self.file, options: .atomic)
        } catch {
            NSLog("Cyclop: cannot write config.json: \(error.localizedDescription)")
        }
    }

    static func reveal() {
        if !FileManager.default.fileExists(atPath: file.path) {
            shared.write(shared.value)
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
