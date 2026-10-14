import AppKit

// The hook's relay is the same executable and must not become an app: this is
// decided before anything of AppKit is touched.
if CommandLine.arguments.dropFirst().first == ClaudeWire.relayArgument {
    let path = CommandLine.arguments.dropFirst(2).first ?? ClaudeWire.defaultSocketPath
    exit(ClaudeRelay.run(socketPath: path))
}

// Top-level code runs on the main thread; make that explicit for the compiler.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // Keep the delegate alive for the lifetime of the process.
    objc_setAssociatedObject(app, "cyclop.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
