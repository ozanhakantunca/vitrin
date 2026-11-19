import AppKit
import VitrinCore
import VitrinSystem

/// Opt-in remote control for development and automated checks, so the switcher can be exercised
/// without a keyboard. Disabled unless explicitly enabled:
///
///     defaults write io.github.ozanhakantunca.vitrin debugCommands -bool true
///
/// Then, from a shell:
///
///     swift scripts/vitrin-debug.swift open all-windows   # also: next, previous, confirm, cancel, settings, type <text>
///     swift scripts/vitrin-debug.swift demo [N] [profile] # panel with N WindowServer windows (no AX needed)
///     swift scripts/vitrin-debug.swift dump               # writes $(getconf DARWIN_USER_TEMP_DIR)vitrin-dump.txt
@MainActor
final class DebugCommands {
    static let notificationName = Notification.Name("io.github.ozanhakantunca.vitrin.debug")
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "debugCommands") }

    private weak var controller: SwitcherController?
    private let windowsDump: () -> String
    private var observer: NSObjectProtocol?

    init(controller: SwitcherController, windowsDump: @escaping () -> String) {
        self.controller = controller
        self.windowsDump = windowsDump
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notificationName, object: nil, queue: .main
        ) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.run(command) }
        }
        Log.app.notice("Debug commands enabled")
    }

    /// Normal-layer windows (all Spaces) from the WindowServer (no Accessibility needed).
    static func windowServerWindows(limit: Int) -> [WindowInfo] {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows: [WindowInfo] = info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 80, bounds.height > 80 else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            return WindowInfo(
                id: id, pid: pid, bundleIdentifier: app?.bundleIdentifier,
                appName: entry[kCGWindowOwnerName as String] as? String ?? app?.localizedName ?? "",
                title: entry[kCGWindowName as String] as? String ?? "", frame: bounds
            )
        }
        return Array(windows.prefix(limit))
    }

    private func run(_ command: String) {
        guard let controller else { return }
        let parts = command.split(separator: " ").map(String.init)
        Log.app.notice("Debug command: \(command, privacy: .public)")
        switch parts.first {
        case "open": controller.openFromScript(profileID: parts.dropFirst().first ?? "all-windows")
        case "next": controller.handle(.next)
        case "previous": controller.handle(.previous)
        case "confirm": controller.handle(.confirm)
        case "cancel": controller.handle(.cancel)
        case "settings": (NSApp.delegate as? AppDelegate)?.showSettings()
        case "type": for character in parts.dropFirst().joined(separator: " ") { controller.handle(.text(String(character))) }
        case "demo":
            let limit = Int(parts.dropFirst().first ?? "") ?? 12
            controller.openDemo(windows: Self.windowServerWindows(limit: limit), profileID: parts.count > 2 ? parts[2] : "all-windows")
        case "dump":
            // Per-user temp dir ($(getconf DARWIN_USER_TEMP_DIR)), readable only by this user.
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("vitrin-dump.txt")
            let text = "AXIsProcessTrusted=\(AXIsProcessTrusted())\n\(controller.debugDescription)\n\n\(windowsDump())"
            try? text.write(to: path, atomically: true, encoding: .utf8)
        default: Log.app.error("Unknown debug command")
        }
    }
}
