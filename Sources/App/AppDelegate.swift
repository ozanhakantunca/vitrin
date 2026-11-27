import AppKit
import Combine
import VitrinCore
import VitrinSystem

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let onboardingShownKey = "onboardingShown"

    let permissions = PermissionManager()
    private var statusMenu: StatusMenu?
    private var onboarding: OnboardingWindowController?
    private var settingsWindow: SettingsWindowController?

    let settingsStore = SettingsStore()
    private var switcher: SwitcherController?
    private var lastWindowQuitter: LastWindowQuitter?
    private var switcherStarted = false
    private var permissionSink: AnyCancellable?
    private var debugCommands: DebugCommands?
    private var takeover: HotkeyTakeover?
    private var configWatcher: ConfigFileWatcher?
    private var recorderSink: AnyCancellable?
    private var cliServer: CLIServer?
    private var updateChecker: UpdateChecker?
    private let gesture = TrackpadGestureRecognizer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateExistingInstanceIfAny() {
            NSApp.terminate(nil)
            return
        }
        Log.app.info("Vitrin \(Self.versionString, privacy: .public) launching")

        statusMenu = StatusMenu(
            permissions: permissions,
            actions: .init(
                showPermissions: { [weak self] in self?.showOnboarding() },
                showSettings: { [weak self] in self?.showSettings() },
                showAbout: { [weak self] in self?.showAbout() },
                loginItemChanged: { [weak self] in self?.syncLaunchAtLoginSetting() }
            )
        )

        LoginItem.applyDefaultOnce()
        syncLaunchAtLoginSetting()
        startSwitcher()

        permissions.refresh()
        let shown = UserDefaults.standard.bool(forKey: Self.onboardingShownKey)
        if !shown || !permissions.accessibilityGranted {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        switcher?.stop()
        cliServer?.stop()
        gesture.stop()
        takeover?.restoreAll()
        configWatcher?.stop()
    }

    // MARK: - Switcher

    private func startSwitcher() {
        // Re-enable a native ⌘Tab that a crashed previous run left disabled, before anything else.
        HotkeyTakeover.recoverFromPreviousRun()
        let settings = settingsStore.settings
        let tracker = WindowTracker()
        let panel = SwitcherPanel()
        let actor = WindowActor(tracker: tracker)
        let controller = SwitcherController(
            settings: settings,
            tracker: tracker,
            actor: actor,
            hotkeys: HotkeyManager(),
            thumbnails: ThumbnailProvider(),
            panel: panel,
            spaces: SpaceSwitcher()
        )
        // Task view: clicking the dimmed background cancels.
        panel.onBackgroundClick = { [weak controller] in controller?.close() }
        switcher = controller
        let quitter = LastWindowQuitter(settings: settings, windows: { tracker.windows },
                                        isTracking: { tracker.isObservingAccessibility })
        lastWindowQuitter = quitter
        controller.onWindowsChange = { [weak quitter] in quitter?.evaluate() }
        // Only take over the native ⌘Tab once our event tap is live; otherwise the user would be left
        // with no ⌘Tab at all (e.g. Accessibility not granted yet).
        let takeover = HotkeyTakeover()
        self.takeover = takeover
        settingsStore.onChange = { [weak self, weak controller] settings in
            controller?.apply(settings: settings)
            quitter.apply(settings: settings)
            if self?.switcherStarted == true { takeover.apply(profiles: settings.profiles) }
            self?.applyAppLevel(settings)
            self?.applyLaunchAtLogin(settings)
        }

        startCLIServer(tracker: tracker, actor: actor, controller: controller)
        gesture.onEvent = { [weak controller] event in controller?.handleGesture(event) }
        let updates = UpdateChecker(currentVersion: Self.versionString)
        updateChecker = updates
        statusMenu?.updateChecker = updates
        applyAppLevel(settings)

        // Hand-edited config (editor, dotfiles sync) is picked up live.
        let watcher = ConfigFileWatcher(url: settingsStore.configURL) { [weak self] in
            self?.settingsStore.reloadFromDisk()
        }
        watcher.start()
        configWatcher = watcher

        // The Settings shortcut recorder must receive keys that Vitrin would otherwise intercept.
        // `@Published` emits before the property changes, so use the emitted value.
        recorderSink = SettingsRecorderState.shared.$isRecording
            .removeDuplicates()
            .sink { [weak controller] recording in controller?.setPaused(recording) }
        if DebugCommands.isEnabled {
            debugCommands = DebugCommands(controller: controller, windowsDump: { tracker.debugDump() })
        }

        // The event tap and AX observation need Accessibility; (re)start as soon as it is granted.
        permissionSink = permissions.$accessibilityGranted
            .removeDuplicates()
            .sink { [weak self] granted in
                guard granted, let self, !self.switcherStarted else { return }
                self.switcherStarted = controller.start()
                tracker.refreshAll()
                if self.switcherStarted { takeover.apply(profiles: self.settingsStore.settings.profiles) }
                self.applyAppLevel(self.settingsStore.settings)
            }
    }

    // MARK: - Launch at login

    /// `launchAtLogin` as last applied; the system's login item is the source of truth.
    private var appliedLaunchAtLogin = false

    /// Makes the config's `launchAtLogin` match the system (it can change in System Settings).
    private func syncLaunchAtLoginSetting() {
        guard LoginItem.isAvailable else { return }
        appliedLaunchAtLogin = LoginItem.isRequested
        settingsStore.settings.launchAtLogin = appliedLaunchAtLogin
    }

    /// Applies an edit of `launchAtLogin` (config file or Settings) to the system.
    private func applyLaunchAtLogin(_ settings: AppSettings) {
        guard LoginItem.isAvailable else { return }
        if let enable = LoginItemPolicy.change(
            previousConfig: appliedLaunchAtLogin, newConfig: settings.launchAtLogin, isRequested: LoginItem.isRequested
        ) {
            LoginItem.setEnabled(enable)
        }
        appliedLaunchAtLogin = settings.launchAtLogin
    }

    /// Settings that live outside the switcher: menu bar icon, update checks.
    private func applyAppLevel(_ settings: AppSettings) {
        statusMenu?.setVisible(settings.showMenuBarIcon)
        updateChecker?.startPeriodicChecks(enabled: settings.checkForUpdates)
        // The gesture drives the switcher, so it only runs once the switcher (event tap, tracking) is live.
        if settings.trackpadGesture && switcherStarted { gesture.start() } else { gesture.stop() }
    }

    private func startCLIServer(tracker: WindowTracker, actor: WindowActor, controller: SwitcherController) {
        let server = CLIServer(
            list: {
                tracker.focusHistory.ordered(tracker.windows).map {
                    CLIWindow(
                        id: $0.id, pid: $0.pid, app: $0.appName, title: $0.title,
                        minimized: $0.isMinimized, hidden: $0.isAppHidden, fullscreen: $0.isFullscreen
                    )
                }
            },
            focus: { id in
                guard let window = tracker.windows.first(where: { $0.id == id }) else { return false }
                return actor.perform(.focus, on: window)
            },
            show: { [weak self, weak controller] requestedID in
                guard let self, let controller else { return false }
                let profiles = self.settingsStore.settings.activeProfiles
                let profile = requestedID.flatMap { id in profiles.first { $0.id == id } } ?? profiles.first
                guard let profile else { return false }
                controller.open(profileID: profile.id, reverse: false)
                return controller.isOpen
            }
        )
        cliServer = server
        if !server.start() { Log.app.error("Could not start the CLI socket") }
    }

    /// Opening Vitrin.app again (e.g. from Finder or Spotlight) shows Settings — the way back
    /// when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    // MARK: - Windows

    func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindowController(permissions: permissions)
        }
        UserDefaults.standard.set(true, forKey: Self.onboardingShownKey)
        onboarding?.show()
    }

    func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(store: settingsStore) }
        settingsWindow?.show()
    }

    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Vitrin",
            .applicationVersion: Self.versionString,
            .version: "",
        ])
    }

    // MARK: - Helpers

    static var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return v ?? VitrinCore.version
    }

    /// Single-instance guard. Returns true if another instance was found (and activated).
    private func activateExistingInstanceIfAny() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        guard let other = others.first else { return false }
        Log.app.info("Another instance (pid \(other.processIdentifier)) is running; exiting")
        other.activate(options: [])
        return true
    }
}
