import AppKit
import VitrinSystem

// Entry point. Top-level code in main.swift runs on the main thread.
MainActor.assumeIsolated {
    // `vitrin list | focus | show | --help | --version` talk to the running app and exit.
    if let code = CLI.runIfRequested(arguments: CommandLine.arguments) {
        exit(code)
    }
    // Diagnostics: print every window Vitrin can see, then exit (needs Accessibility for full detail).
    if CommandLine.arguments.contains("--dump-windows") {
        print(WindowTracker.dumpWithoutStarting())
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // No Dock icon, even when run unbundled (Info.plist also sets LSUIElement).
    app.setActivationPolicy(.accessory)
    app.run()
}
