import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let permissions: PermissionManager
    private let window: NSWindow

    init(permissions: PermissionManager) {
        self.permissions = permissions
        window = NSWindow()
        super.init()
        let view = OnboardingView(permissions: permissions) { [weak self] in
            self?.window.close()
        }
        window.contentViewController = NSHostingController(rootView: view)
        window.title = String(localized: "Welcome to Vitrin")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    func show() {
        permissions.onboardingVisible = true
        permissions.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        permissions.onboardingVisible = false
    }
}
