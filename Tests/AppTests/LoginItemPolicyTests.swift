import Testing
@testable import Vitrin

@Test func launchAtLoginIsTurnedOnOnceByDefault() {
    #expect(LoginItemPolicy.shouldEnableByDefault(isAvailable: true, defaultApplied: false, isRequested: false))
    #expect(!LoginItemPolicy.shouldEnableByDefault(isAvailable: true, defaultApplied: true, isRequested: false))
    #expect(!LoginItemPolicy.shouldEnableByDefault(isAvailable: true, defaultApplied: false, isRequested: true))
    #expect(!LoginItemPolicy.shouldEnableByDefault(isAvailable: false, defaultApplied: false, isRequested: false))
}

@Test func onlyAnEditOfLaunchAtLoginChangesTheLoginItem() {
    // Edited in the config file.
    #expect(LoginItemPolicy.change(previousConfig: false, newConfig: true, isRequested: false) == true)
    #expect(LoginItemPolicy.change(previousConfig: true, newConfig: false, isRequested: true) == false)
    // Already matches the system (e.g. the Settings toggle changed it first).
    #expect(LoginItemPolicy.change(previousConfig: false, newConfig: true, isRequested: true) == nil)
    // Unchanged but stale (turned off in System Settings): another setting changed, leave it alone.
    #expect(LoginItemPolicy.change(previousConfig: true, newConfig: true, isRequested: false) == nil)
}
