import AppKit

/// Menu bar item and its menu.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    struct Actions {
        var showPermissions: () -> Void
        var showSettings: () -> Void
        var showAbout: () -> Void
        /// The login item was toggled from the menu.
        var loginItemChanged: () -> Void = {}
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let permissions: PermissionManager
    private let actions: Actions

    private let accessibilityItem = NSMenuItem()
    private let screenRecordingItem = NSMenuItem()
    private let loginItem = NSMenuItem()
    /// Set by the app delegate; an "Update available" item appears at the top when it reports one.
    var updateChecker: UpdateChecker?
    private var updateItems: [NSMenuItem] = []

    init(permissions: PermissionManager, actions: Actions) {
        self.permissions = permissions
        self.actions = actions
        super.init()
        configureButton()
        buildMenu()
    }

    private func configureButton() {
        let image = NSImage(
            systemSymbolName: "rectangle.on.rectangle",
            accessibilityDescription: "Vitrin"
        )
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Vitrin"
    }

    private func buildMenu() {
        menu.delegate = self
        for item in [accessibilityItem, screenRecordingItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(item(String(localized: "Show Permissions…"), #selector(showPermissions)))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Settings…"), #selector(showSettings), key: ","))
        loginItem.title = String(localized: "Launch at Login")
        loginItem.action = #selector(toggleLogin)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "About Vitrin"), #selector(showAbout)))
        menu.addItem(item(String(localized: "Quit Vitrin"), #selector(quit), key: "q"))
        statusItem.menu = menu
        refresh()
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// Hides or shows the menu bar icon (`settings.showMenuBarIcon`). Reopening Vitrin.app shows Settings.
    func setVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    private func refreshUpdateItem() {
        for item in updateItems { menu.removeItem(item) }
        updateItems = []
        guard let checker = updateChecker, let item = UpdateMenuItem.make(for: checker) else { return }
        updateItems = [item, .separator()]
        menu.insertItem(updateItems[1], at: 0)
        menu.insertItem(item, at: 0)
    }

    private func refresh() {
        refreshUpdateItem()
        permissions.refresh()
        accessibilityItem.title = permissions.accessibilityGranted
            ? String(localized: "✓ Accessibility")
            : String(localized: "⚠ Accessibility (required)")
        screenRecordingItem.title = permissions.screenRecordingGranted
            ? String(localized: "✓ Screen Recording")
            : String(localized: "⚠ Screen Recording (optional)")

        loginItem.isEnabled = LoginItem.isAvailable
        loginItem.state = LoginItem.isEnabled ? .on : (LoginItem.requiresApproval ? .mixed : .off)
        loginItem.toolTip = LoginItem.isAvailable
            ? (LoginItem.requiresApproval
                ? String(localized: "Approve Vitrin in System Settings → Login Items")
                : nil)
            : String(localized: "Available when running from Vitrin.app")
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    @objc private func showPermissions() { actions.showPermissions() }
    @objc private func showSettings() { actions.showSettings() }
    @objc private func showAbout() { actions.showAbout() }
    @objc private func toggleLogin() {
        LoginItem.toggle()
        actions.loginItemChanged()
        refresh()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
