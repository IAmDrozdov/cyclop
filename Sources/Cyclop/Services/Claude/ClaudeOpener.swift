import AppKit

/// An app that owns a session's process: the editor or the terminal it runs in.
struct ClaudeHostApp: Equatable {
    let url: URL
    /// The editor's own link scheme (`cursor`, `vscode`), from its Info.plist.
    let urlScheme: String?
}

/// What Open in Claude does to the system. Neither call needs a macOS permission.
@MainActor
protocol ClaudeOpening {
    /// The app a process was started from, found through its ancestors.
    func hostApp(ofProcess pid: Int) -> ClaudeHostApp?
    func open(_ url: URL)
    func bringForward(_ app: ClaudeHostApp)
}

struct SystemClaudeOpener: ClaudeOpening {
    func hostApp(ofProcess pid: Int) -> ClaudeHostApp? {
        guard let url = ProcessTable.owningApp(of: pid) else { return nil }
        let types = Bundle(url: url)?.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]]
        let scheme = types?.compactMap { ($0["CFBundleURLSchemes"] as? [String])?.first }.first
        return ClaudeHostApp(url: url, urlScheme: scheme)
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func bringForward(_ app: ClaudeHostApp) {
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
    }
}
