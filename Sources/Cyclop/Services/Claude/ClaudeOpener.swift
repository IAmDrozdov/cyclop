import AppKit

/// An app that owns a session's process: the editor or the terminal it runs in.
struct ClaudeHostApp: Equatable {
    let url: URL
    /// The editor's own link scheme (`cursor`, `vscode`), from its Info.plist.
    let urlScheme: String?
    /// `com.apple.Terminal`; read from the bundle when not given.
    var bundleID: String? = nil
}

/// How a terminal script ended: Automation refused (error -1743) is told apart from any other failure.
enum ClaudeTerminalResult: Equatable, Sendable {
    case done
    case automationDenied
    case failed
}

/// What Open in Claude and a hand-off do to the system. Only `focusTab` and `runInTerminal` need a macOS permission (Automation).
@MainActor
protocol ClaudeOpening {
    /// The app a process was started from, found through its ancestors.
    func hostApp(ofProcess pid: Int) -> ClaudeHostApp?
    func open(_ url: URL)
    func bringForward(_ app: ClaudeHostApp)
    /// Selects the terminal tab that holds the process; false when it could not.
    func focusTab(ofProcess pid: Int, in app: ClaudeHostApp) -> Bool
    /// Runs the command in a new tab of the terminal window that holds the process (a new window when it is
    /// not found, and always in Terminal). Off the main thread: the script waits on the terminal and on consent.
    func runInTerminal(_ command: String, besideProcess pid: Int, in app: ClaudeHostApp) async -> ClaudeTerminalResult
    func copyToPasteboard(_ text: String)
}

struct SystemClaudeOpener: ClaudeOpening {
    func hostApp(ofProcess pid: Int) -> ClaudeHostApp? {
        guard let url = ProcessTable.owningApp(of: pid) else { return nil }
        let types = Bundle(url: url)?.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]]
        let scheme = types?.compactMap { ($0["CFBundleURLSchemes"] as? [String])?.first }.first
        return ClaudeHostApp(url: url, urlScheme: scheme, bundleID: Bundle(url: url)?.bundleIdentifier)
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func bringForward(_ app: ClaudeHostApp) {
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
    }

    func focusTab(ofProcess pid: Int, in app: ClaudeHostApp) -> Bool {
        guard let id = app.bundleID ?? Bundle(url: app.url)?.bundleIdentifier, let source = Self.scripts[id],
            let tty = ProcessTable.tty(of: pid)
        else { return false }
        return Self.call("focus", in: source, arguments: [tty]).done
    }

    func runInTerminal(_ command: String, besideProcess pid: Int, in app: ClaudeHostApp) async -> ClaudeTerminalResult {
        guard let id = app.bundleID ?? Bundle(url: app.url)?.bundleIdentifier, let source = Self.launchScripts[id]
        else { return .failed }
        let tty = ProcessTable.tty(of: pid) ?? ""
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let end = Self.call("startcommand", in: source, arguments: [command, tty])
                continuation.resume(returning: end.done ? .done : end.errorNumber == -1743 ? .automationDenied : .failed)
            }
        }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

    /// The command and the tty go in as the handler's arguments, never into the source. Both scripts return true
    /// once the command was typed. Terminal's `do script` opens a new window (a tab needs GUI scripting, which
    /// is Accessibility); iTerm gets a new tab in the window that holds the tty, else a new window.
    private static let launchScripts: [String: String] = [
        "com.apple.Terminal": """
        on startcommand(theCommand, theTTY)
            tell application id "com.apple.Terminal"
                do script theCommand
                activate
            end tell
            return true
        end startcommand
        """,
        "com.googlecode.iterm2": """
        on startcommand(theCommand, theTTY)
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is theTTY then
                                tell w
                                    set newTab to (create tab with default profile)
                                    tell current session of newTab to write text theCommand
                                end tell
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
                set newWindow to (create window with default profile)
                tell current session of newWindow to write text theCommand
                activate
            end tell
            return true
        end startcommand
        """,
    ]

    /// Calls the script's handler with text arguments; `done` is false on any error, with its number
    /// (-1743 when Automation is refused).
    private nonisolated static func call(
        _ handler: String, in source: String, arguments texts: [String]
    ) -> (done: Bool, errorNumber: Int?) {
        guard let script = NSAppleScript(source: source) else { return (false, nil) }
        let call = NSAppleEventDescriptor(
            eventClass: fourCC("ascr"), eventID: fourCC("psbr"),
            targetDescriptor: .null(), returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        call.setParam(NSAppleEventDescriptor(string: handler), forKeyword: fourCC("snam"))
        let arguments = NSAppleEventDescriptor.list()
        for (index, text) in texts.enumerated() {
            arguments.insert(NSAppleEventDescriptor(string: text), at: index + 1)
        }
        call.setParam(arguments, forKeyword: fourCC("----"))
        var error: NSDictionary?
        let result = script.executeAppleEvent(call, error: &error)
        return (error == nil && result.booleanValue, error?["NSAppleScriptErrorNumber"] as? Int)
    }

    private nonisolated static func fourCC(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
