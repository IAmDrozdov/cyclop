import AppKit

/// An app that owns a session's process: the editor or the terminal it runs in.
struct ClaudeHostApp: Equatable {
    let url: URL
    /// The editor's own link scheme (`cursor`, `vscode`), from its Info.plist.
    let urlScheme: String?
}

/// What Open in Claude does to the system. Only `focusTab` needs a macOS permission (Automation).
@MainActor
protocol ClaudeOpening {
    /// The app a process was started from, found through its ancestors.
    func hostApp(ofProcess pid: Int) -> ClaudeHostApp?
    func open(_ url: URL)
    func bringForward(_ app: ClaudeHostApp)
    /// Selects the terminal tab that holds the process; false when it could not.
    func focusTab(ofProcess pid: Int, in app: ClaudeHostApp) -> Bool
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

    func focusTab(ofProcess pid: Int, in app: ClaudeHostApp) -> Bool {
        guard let id = Bundle(url: app.url)?.bundleIdentifier, let source = Self.scripts[id],
            let tty = ProcessTable.tty(of: pid)
        else { return false }
        return Self.run(source, tty: tty)
    }

    /// The tty goes in as the handler's argument, never into the source. Both scripts return true
    /// when a tab with that tty was found and shown.
    private static let scripts: [String: String] = [
        "com.apple.Terminal": """
        on focus(theTTY)
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is theTTY then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
        end focus
        """,
        "com.googlecode.iterm2": """
        on focus(theTTY)
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is theTTY then
                                select s
                                select t
                                select w
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
        end focus
        """,
    ]

    /// Calls `focus(tty)` of the script; any error (-1743 when Automation is refused) is false.
    private static func run(_ source: String, tty: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        let call = NSAppleEventDescriptor(
            eventClass: fourCC("ascr"), eventID: fourCC("psbr"),
            targetDescriptor: .null(), returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        call.setParam(NSAppleEventDescriptor(string: "focus"), forKeyword: fourCC("snam"))
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: tty), at: 1)
        call.setParam(arguments, forKeyword: fourCC("----"))
        var error: NSDictionary?
        let result = script.executeAppleEvent(call, error: &error)
        return error == nil && result.booleanValue
    }

    private static func fourCC(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
