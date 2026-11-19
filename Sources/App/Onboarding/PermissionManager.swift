import AppKit
import ApplicationServices
import CoreGraphics

/// Tracks Accessibility (required) and Screen Recording (optional) permissions.
/// Polls once per second only while the onboarding window is visible or Accessibility (required) is missing.
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var screenRecordingGranted = false
    /// The user asked for Screen Recording; it usually only takes effect after a relaunch.
    @Published private(set) var screenRecordingRequested = false

    var onboardingVisible = false {
        didSet { updatePolling() }
    }

    private var timer: Timer?

    static let accessibilityURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let screenRecordingURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    var allGranted: Bool { accessibilityGranted && screenRecordingGranted }

    init() { refresh() }

    func refresh() {
        let ax = AXIsProcessTrusted()
        let sr = CGPreflightScreenCaptureAccess()
        if ax != accessibilityGranted { accessibilityGranted = ax }
        if sr != screenRecordingGranted { screenRecordingGranted = sr }
        updatePolling()
    }

    /// Shows the system Accessibility prompt (user action only) and opens the settings pane.
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if !AXIsProcessTrusted() { NSWorkspace.shared.open(Self.accessibilityURL) }
        refresh()
    }

    func requestScreenRecording() {
        screenRecordingRequested = true
        if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(Self.screenRecordingURL) }
        refresh()
    }

    /// Relaunches the bundle (needed for Screen Recording to take effect), then quits.
    func relaunch() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { return }
        // Delay the new launch until this process is gone so single-instance check passes.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.7; /usr/bin/open -n \"$0\"", path]
        do { try process.run() } catch {
            Log.permissions.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }

    private func updatePolling() {
        let shouldPoll = onboardingVisible || !accessibilityGranted
        if shouldPoll, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        } else if !shouldPoll, let t = timer {
            t.invalidate()
            timer = nil
        }
    }
}
