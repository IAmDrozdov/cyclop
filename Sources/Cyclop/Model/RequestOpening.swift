/// When the panel slides out by itself for a Claude request.
enum RequestOpening {
    /// Only onto a notch with nothing showing: a panel the owner has open, a teleprompter
    /// included, is never moved or covered by a request.
    static func shouldOpen(enabled: Bool, claudeVisible: Bool, anyPanelActive: Bool) -> Bool {
        enabled && claudeVisible && !anyPanelActive
    }
}
