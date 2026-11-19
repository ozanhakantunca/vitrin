import CoreGraphics
import Testing
import VitrinCore
@testable import VitrinSystem

struct HotkeyMatcherTests {
    private func profile(
        _ id: String = "all", modifiers: ModifierSet = .option, key: KeyCombo.Key = .tab,
        enabled: Bool = true, release: ReleaseBehavior = .focusSelection
    ) -> ShortcutProfile {
        ShortcutProfile(
            id: id, name: id, isEnabled: enabled,
            trigger: KeyCombo(modifiers: modifiers, key: key), releaseBehavior: release
        )
    }

    private func opened(
        _ matcher: HotkeyMatcher, code: UInt16 = KeyCode.tab, flags: CGEventFlags = .maskAlternate,
        id: String = "all"
    ) -> HotkeyMatcher.State {
        var state = HotkeyMatcher.State()
        #expect(matcher.handle(.init(type: .keyDown, keyCode: code, flags: flags), state: &state)
            == .init(swallow: true, event: .open(profileID: id, reverse: flags.contains(.maskShift))))
        state.openProfileID = id
        state.isSwitcherOpen = true
        #expect(matcher.synchronize(state: &state) == nil)
        return state
    }

    @Test func triggerMatchesAndRejectsExtraOrMissingModifiers() {
        let matcher = HotkeyMatcher(profiles: [profile()])
        var state = HotkeyMatcher.State()
        #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: .maskAlternate), state: &state)
            == .init(swallow: true, event: .open(profileID: "all", reverse: false)))
        for flags: CGEventFlags in [[], .maskCommand, [.maskAlternate, .maskCommand],
                                   [.maskAlternate, .maskControl], [.maskAlternate, .maskControl, .maskCommand]] {
            var fresh = HotkeyMatcher.State()
            #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: flags), state: &fresh)
                == .init(swallow: false))
        }
        #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.space, flags: .maskAlternate), state: &state)
            == .init(swallow: false))
    }

    @Test func allModifierCombinationsAreComparedExactlyExceptOptionalShiftAndFn() {
        let flagBits: [CGEventFlags] = [.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn]
        for requiredRaw in UInt8(0)..<32 {
            let required = ModifierSet(rawValue: requiredRaw)
            let matcher = HotkeyMatcher(profiles: [profile(modifiers: required)])
            for actualRaw in UInt8(0)..<32 {
                let flags = flagBits.enumerated().reduce(CGEventFlags()) { result, element in
                    actualRaw & (1 << element.offset) != 0 ? result.union(element.element) : result
                }
                var compared = actualRaw
                if !required.contains(.shift) { compared &= ~ModifierSet.shift.rawValue }
                if !required.contains(.function) { compared &= ~ModifierSet.function.rawValue }
                var state = HotkeyMatcher.State()
                let result = matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: flags), state: &state)
                #expect(result.swallow == (compared == requiredRaw))
                #expect(result.event == (compared == requiredRaw
                    ? .open(profileID: "all", reverse: flags.contains(.maskShift)) : nil))
            }
        }
    }

    @Test func shiftOpensInReverseAndNavigatesBackward() {
        let matcher = HotkeyMatcher(profiles: [profile()])
        var state = opened(matcher, flags: [.maskAlternate, .maskShift])
        #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: [.maskAlternate, .maskShift]), state: &state)
            == .init(swallow: true, event: .previous))
        #expect(matcher.handle(.init(type: .flagsChanged, flags: .maskAlternate), state: &state)
            == .init(swallow: false)) // Optional reverse Shift is not a hold modifier.
        #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: .maskAlternate), state: &state)
            == .init(swallow: true, event: .next))
    }

    @Test func capsLockDeviceFlagsAndUnusedFnAreIgnored() {
        let matcher = HotkeyMatcher(profiles: [profile()])
        var state = HotkeyMatcher.State()
        let flags = CGEventFlags.maskAlternate.union(.maskAlphaShift).union(.maskSecondaryFn)
            .union(.maskNumericPad).union(CGEventFlags(rawValue: 0x20))
        #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: flags), state: &state)
            == .init(swallow: true, event: .open(profileID: "all", reverse: false)))
    }

    @Test(arguments: [false, true])
    func keyAboveTabResolvesForKeyboardType(isISO: Bool) {
        let matcher = HotkeyMatcher(profiles: [profile(key: .keyAboveTab)], isISOKeyboard: isISO)
        let correct = isISO ? KeyCode.isoSection : KeyCode.grave
        let wrong = isISO ? KeyCode.grave : KeyCode.isoSection
        var state = HotkeyMatcher.State()
        #expect(matcher.handle(.init(type: .keyDown, keyCode: wrong, flags: .maskAlternate), state: &state)
            == .init(swallow: false))
        state = opened(matcher, code: correct)
        #expect(matcher.handle(.init(type: .keyDown, keyCode: correct, flags: .maskAlternate), state: &state)
            == .init(swallow: true, event: .next))
    }

    @Test func keyboardTypeCanChangeBetweenOpens() {
        var matcher = HotkeyMatcher(profiles: [profile(key: .keyAboveTab)])
        var state = opened(matcher, code: KeyCode.grave)
        state.isSwitcherOpen = false
        matcher.close(state: &state)
        matcher.isISOKeyboard = true
        #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.isoSection, flags: .maskAlternate), state: &state)
            == .init(swallow: true, event: .open(profileID: "all", reverse: false)))
    }

    @Test func everyNavigationActionAndEditingKeyIsMapped() {
        let mappings: [(UInt16, HotkeyEvent)] = [
            (0x7B, .moveLeft), (0x7C, .moveRight), (0x7E, .moveUp), (0x7D, .moveDown),
            (0x24, .confirm), (0x4C, .confirm), (KeyCode.space, .text(" ")), (KeyCode.escape, .cancel),
            (0x75, .action(.close)), (0x33, .backspace),
        ]
        let matcher = HotkeyMatcher(profiles: [profile()])
        var state = opened(matcher)
        for (code, expected) in mappings {
            #expect(matcher.handle(.init(type: .keyDown, keyCode: code, flags: .maskAlternate), state: &state)
                == .init(swallow: true, event: expected))
            #expect(matcher.handle(.init(type: .keyUp, keyCode: code, flags: .maskAlternate), state: &state)
                == .init(swallow: true))
        }
    }

    @Test func windowActionsNeedCommandAndPlainLettersSearch() {
        let actions: [(UInt16, WindowAction)] = [
            (0x0D, .close), (0x2E, .minimize), (0x03, .toggleFullscreen), (0x04, .hideApp), (0x0C, .quitApp),
        ]
        let matcher = HotkeyMatcher(profiles: [profile()])
        var state = opened(matcher)
        for (code, action) in actions {
            #expect(matcher.handle(.init(type: .flagsChanged, keyCode: 0x37, flags: [.maskAlternate, .maskCommand]), state: &state)
                == .init(swallow: false))
            #expect(matcher.handle(.init(type: .keyDown, keyCode: code, flags: [.maskAlternate, .maskCommand]), state: &state)
                == .init(swallow: true, event: .action(action)))
            #expect(matcher.handle(.init(type: .flagsChanged, keyCode: 0x37, flags: .maskAlternate), state: &state)
                == .init(swallow: false))
            #expect(matcher.handle(.init(type: .keyDown, keyCode: code, flags: .maskAlternate, text: "w"), state: &state)
                == .init(swallow: true, event: .text("w")))
        }
    }

    @Test func controlAlsoFiresWindowActionsWhileOptionIsHeld() {
        let actions: [(UInt16, WindowAction)] = [
            (0x0D, .close), (0x2E, .minimize), (0x03, .toggleFullscreen), (0x04, .hideApp), (0x0C, .quitApp),
        ]
        let matcher = HotkeyMatcher(profiles: [profile()])
        var state = opened(matcher)
        for (code, action) in actions {
            #expect(matcher.handle(.init(type: .keyDown, keyCode: code, flags: [.maskAlternate, .maskControl]), state: &state)
                == .init(swallow: true, event: .action(action)))
            // ⌘ still works.
            #expect(matcher.handle(.init(type: .keyDown, keyCode: code, flags: [.maskAlternate, .maskCommand]), state: &state)
                == .init(swallow: true, event: .action(action)))
            // Plain and ⌥-only letters stay search text.
            #expect(matcher.handle(.init(type: .keyDown, keyCode: code, flags: .maskAlternate, text: "w"), state: &state)
                == .init(swallow: true, event: .text("w")))
        }
    }

    @Test func controlWithOtherLettersDoesNotBecomeAnAction() {
        let matcher = HotkeyMatcher(profiles: [profile()])
        var state = opened(matcher)
        #expect(matcher.handle(.init(type: .keyDown, keyCode: 0x00, flags: [.maskAlternate, .maskControl], text: "a"), state: &state)
            == .init(swallow: true, event: .text("a")))
    }

    @Test func controlWindowActionsDoNothingWhileClosed() {
        let matcher = HotkeyMatcher(profiles: [profile()])
        for code: UInt16 in [0x0D, 0x2E, 0x03, 0x04, 0x0C] {
            var state = HotkeyMatcher.State()
            #expect(matcher.handle(.init(type: .keyDown, keyCode: code, flags: [.maskAlternate, .maskControl]), state: &state)
                == .init(swallow: false))
            #expect(matcher.handle(.init(type: .keyDown, keyCode: code, flags: .maskControl), state: &state)
                == .init(swallow: false))
        }
    }

    @Test func unicodeTextIsPreservedAndNonprintableTextIsIgnored() {
        let matcher = HotkeyMatcher(profiles: [profile()])
        var state = opened(matcher)
        for text in ["a", "A", "å", "İ", "你好", "👩🏽‍💻", "e\u{301}", "42"] {
            #expect(matcher.handle(.init(type: .keyDown, keyCode: 0x00, flags: .maskAlternate, text: text), state: &state)
                == .init(swallow: true, event: .text(text)))
        }
        for text in [nil, "", "\n", "\t", "\u{7F}", "\u{F700}", "\u{2028}", "\u{2029}", "a\n"] as [String?] {
            #expect(matcher.handle(.init(type: .keyDown, keyCode: 0x60, flags: .maskAlternate, text: text), state: &state)
                == .init(swallow: true))
        }
    }

    @Test func allKeysAreSwallowedWhileOpenButFlagsNeverAre() {
        let matcher = HotkeyMatcher(profiles: [profile()])
        var state = opened(matcher)
        for code in UInt16(0)...127 {
            #expect(matcher.handle(.init(type: .keyDown, keyCode: code, flags: .maskAlternate), state: &state).swallow)
            #expect(matcher.handle(.init(type: .keyUp, keyCode: code, flags: .maskAlternate), state: &state).swallow)
        }
        #expect(matcher.handle(.init(type: .flagsChanged, flags: [.maskAlternate, .maskShift]), state: &state)
            == .init(swallow: false))
        #expect(matcher.handle(.init(type: .flagsChanged), state: &state)
            == .init(swallow: false, event: .modifiersReleased))
        #expect(matcher.handle(.init(type: .flagsChanged), state: &state)
            == .init(swallow: false))
    }

    @Test func triggerKeyUpIsSwallowedWithoutOpeningThePanel() {
        let matcher = HotkeyMatcher(profiles: [profile()])
        var state = HotkeyMatcher.State()
        _ = matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: .maskAlternate), state: &state)
        #expect(matcher.handle(.init(type: .keyUp, keyCode: KeyCode.tab), state: &state)
            == .init(swallow: true))
        #expect(matcher.handle(.init(type: .keyUp, keyCode: KeyCode.tab), state: &state)
            == .init(swallow: false))
        #expect(matcher.handle(.init(type: .keyUp, keyCode: 0x00), state: &state)
            == .init(swallow: false))
    }

    @Test func swallowedKeyUpsSurviveClosingAndRepeatsDoNotReopen() {
        let matcher = HotkeyMatcher(profiles: [profile()])
        var state = opened(matcher)
        _ = matcher.handle(.init(type: .keyDown, keyCode: 0x24, flags: .maskAlternate), state: &state)
        state.isSwitcherOpen = false
        matcher.close(state: &state)
        #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: .maskAlternate, isAutorepeat: true), state: &state)
            == .init(swallow: true))
        for code: UInt16 in [0x24, KeyCode.tab] {
            #expect(matcher.handle(.init(type: .keyUp, keyCode: code), state: &state)
                == .init(swallow: true))
        }
        #expect(matcher.handle(.init(type: .keyDown, keyCode: 0x00), state: &state)
            == .init(swallow: false))
    }

    @Test func releasingAnyRequiredModifierEmitsExactlyOnce() {
        let matcher = HotkeyMatcher(profiles: [profile(modifiers: [.option, .command, .shift, .function])])
        let all: CGEventFlags = [.maskAlternate, .maskCommand, .maskShift, .maskSecondaryFn]
        for released: CGEventFlags in [.maskAlternate, .maskCommand, .maskShift, .maskSecondaryFn] {
            var state = opened(matcher, flags: all)
            #expect(matcher.handle(.init(type: .flagsChanged, flags: all.subtracting(released)), state: &state)
                == .init(swallow: false, event: .modifiersReleased))
            #expect(matcher.handle(.init(type: .flagsChanged, flags: []), state: &state)
                == .init(swallow: false))
            #expect(matcher.handle(.init(type: .flagsChanged, flags: all), state: &state)
                == .init(swallow: false))
            #expect(matcher.handle(.init(type: .flagsChanged, flags: []), state: &state)
                == .init(swallow: false))
        }
    }

    @Test(arguments: [false, true])
    func fastTapReleaseIsDeliveredWhenPanelEventuallyOpens(profileFirst: Bool) {
        let matcher = HotkeyMatcher(profiles: [profile()])
        var state = HotkeyMatcher.State()
        _ = matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: .maskAlternate), state: &state)
        #expect(matcher.handle(.init(type: .flagsChanged), state: &state)
            == .init(swallow: false))
        #expect(matcher.handle(.init(type: .keyUp, keyCode: KeyCode.tab), state: &state)
            == .init(swallow: true))
        if profileFirst {
            state.openProfileID = "all"
        } else {
            state.isSwitcherOpen = true
        }
        #expect(matcher.synchronize(state: &state) == (profileFirst ? nil : .modifiersReleased))
        if profileFirst {
            state.isSwitcherOpen = true
        } else {
            state.openProfileID = "all"
        }
        #expect(matcher.synchronize(state: &state) == (profileFirst ? .modifiersReleased : nil))
        #expect(matcher.synchronize(state: &state) == nil)
    }

    @Test func fastTapReleaseStaysLatchedEvenIfModifierIsPressedAgain() {
        let matcher = HotkeyMatcher(profiles: [profile()])
        var state = HotkeyMatcher.State()
        _ = matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: .maskAlternate), state: &state)
        _ = matcher.handle(.init(type: .flagsChanged), state: &state)
        _ = matcher.handle(.init(type: .flagsChanged, flags: .maskAlternate), state: &state)
        state.isSwitcherOpen = true
        state.openProfileID = "all"
        #expect(matcher.synchronize(state: &state) == .modifiersReleased)
        #expect(matcher.synchronize(state: &state) == nil)
    }

    @Test func openingSnapshotSurvivesAStaleProfileIDUntilControllerUpdatesIt() {
        let matcher = HotkeyMatcher(profiles: [profile(), profile("current", modifiers: .command, key: .grave)])
        var state = opened(matcher)
        state.isSwitcherOpen = false
        matcher.close(state: &state)
        _ = matcher.handle(.init(type: .keyDown, keyCode: KeyCode.grave, flags: .maskCommand), state: &state)
        _ = matcher.handle(.init(type: .flagsChanged), state: &state)
        state.isSwitcherOpen = true // Controller sets these properties in the opposite order this time.
        #expect(matcher.synchronize(state: &state) == .modifiersReleased)
        state.openProfileID = "current"
        #expect(matcher.synchronize(state: &state) == nil)
        #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.grave), state: &state)
            == .init(swallow: true, event: .next))
    }

    @Test(arguments: [false, true])
    func releaseIsObservedFromKeyEventsEvenWithoutFlagsChanged(onKeyDown: Bool) {
        let matcher = HotkeyMatcher(profiles: [profile()])
        var state = opened(matcher)
        #expect(matcher.handle(.init(type: onKeyDown ? .keyDown : .keyUp, keyCode: KeyCode.tab), state: &state)
            == .init(swallow: true, event: .modifiersReleased))
        #expect(matcher.handle(.init(type: .flagsChanged), state: &state)
            == .init(swallow: false))
    }

    @Test func repeatsContinueNavigationInBothDirections() {
        let matcher = HotkeyMatcher(profiles: [profile()])
        var state = opened(matcher)
        for _ in 0..<5 {
            #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: .maskAlternate, isAutorepeat: true), state: &state)
                == .init(swallow: true, event: .next))
        }
        #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: [.maskAlternate, .maskShift], isAutorepeat: true), state: &state)
            == .init(swallow: true, event: .previous))
    }

    @Test func enabledProfilesMatchIndependentlyAndFirstDuplicateWins() {
        let disabled = profile("disabled", enabled: false)
        let unassigned = ShortcutProfile(id: "none", name: "none", trigger: nil)
        let matcher = HotkeyMatcher(profiles: [disabled, unassigned, profile(), profile("duplicate"),
                                               profile("current", modifiers: .command, key: .keyAboveTab)])
        var state = opened(matcher)
        #expect(matcher.triggers.count == 3)
        #expect(matcher.overlappingTriggers.count == 1)
        #expect(matcher.overlappingTriggers.first?.first == "all")
        #expect(matcher.overlappingTriggers.first?.later == "duplicate")
        state.isSwitcherOpen = false
        state.openProfileID = nil
        matcher.close(state: &state)
        #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.grave, flags: .maskCommand), state: &state)
            == .init(swallow: true, event: .open(profileID: "current", reverse: false)))
        state.openProfileID = "current"
        state.isSwitcherOpen = true
        #expect(matcher.handle(.init(type: .flagsChanged, flags: [.maskCommand, .maskAlternate]), state: &state)
            == .init(swallow: false))
        #expect(matcher.handle(.init(type: .flagsChanged, flags: .maskCommand), state: &state)
            == .init(swallow: false)) // Option belongs to the other profile.
        #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.grave, flags: .maskCommand), state: &state)
            == .init(swallow: true, event: .next))
        #expect(matcher.handle(.init(type: .flagsChanged), state: &state)
            == .init(swallow: false, event: .modifiersReleased))
    }

    @Test func optionalShiftAndFnAndSemanticKeysDetectOverlappingTriggers() {
        let matcher = HotkeyMatcher(profiles: [profile(), profile("shift", modifiers: [.option, .shift]),
                                               profile("fn", modifiers: [.option, .function]),
                                               profile("above", key: .keyAboveTab), profile("grave", key: .grave)])
        #expect(matcher.overlappingTriggers.count == 3)
        var state = HotkeyMatcher.State()
        #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: [.maskAlternate, .maskShift]), state: &state)
            == .init(swallow: true, event: .open(profileID: "all", reverse: true)))
    }

    @Test func updatingProfilesReplacesTriggersButPreservesOpenSessionHoldModifiers() {
        var matcher = HotkeyMatcher(profiles: [profile()])
        var state = opened(matcher)
        matcher = HotkeyMatcher(profiles: [profile("new", modifiers: .command, key: .space)])
        #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: .maskAlternate), state: &state)
            == .init(swallow: true, event: .next))
        #expect(matcher.handle(.init(type: .flagsChanged), state: &state)
            == .init(swallow: false, event: .modifiersReleased))
        state.isSwitcherOpen = false
        matcher.close(state: &state)
        #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: .maskAlternate), state: &state)
            == .init(swallow: false))
        #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.space, flags: .maskCommand), state: &state)
            == .init(swallow: true, event: .open(profileID: "new", reverse: false)))
    }

    @Test func releaseBehaviorRemainsTheControllersDecisionAndNewSessionsResetRelease() {
        let matcher = HotkeyMatcher(profiles: [profile(release: .keepOpen)])
        var state = HotkeyMatcher.State()
        for _ in 0..<2 {
            #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: .maskAlternate), state: &state)
                == .init(swallow: true, event: .open(profileID: "all", reverse: false)))
            state.openProfileID = "all"
            state.isSwitcherOpen = true
            #expect(matcher.synchronize(state: &state) == nil)
            #expect(matcher.handle(.init(type: .flagsChanged), state: &state)
                == .init(swallow: false, event: .modifiersReleased))
            #expect(state.isSwitcherOpen)
            #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab), state: &state)
                == .init(swallow: true, event: .next))
            state.isSwitcherOpen = false
            matcher.close(state: &state)
            #expect(matcher.handle(.init(type: .keyUp, keyCode: KeyCode.tab), state: &state)
                == .init(swallow: true))
        }
    }

    // MARK: App exceptions (ignoreShortcutsWhenFrontmost)

    private let vm = AppException(bundleIdentifier: "com.example.vm", ignoreShortcutsWhenFrontmost: true)

    @Test func triggersPassThroughWhileAnIgnoringAppIsFrontmost() {
        let matcher = HotkeyMatcher(profiles: [profile()], exceptions: [vm])
        var state = HotkeyMatcher.State()
        state.frontmostBundleID = "com.example.vm"
        #expect(matcher.isPassthrough(state))
        let down = HotkeyMatcher.Input(type: .keyDown, keyCode: KeyCode.tab, flags: .maskAlternate)
        #expect(matcher.handle(down, state: &state) == .init(swallow: false))
        #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: [.maskAlternate, .maskShift]),
                               state: &state) == .init(swallow: false))
        #expect(matcher.handle(.init(type: .keyUp, keyCode: KeyCode.tab, flags: .maskAlternate), state: &state)
            == .init(swallow: false))
        #expect(matcher.handle(.init(type: .flagsChanged), state: &state) == .init(swallow: false))

        // Another app comes to the front: the trigger works again.
        state.frontmostBundleID = "com.apple.Safari"
        #expect(matcher.handle(down, state: &state) == .init(swallow: true, event: .open(profileID: "all", reverse: false)))
    }

    @Test func exceptionsWithoutTheFlagOrWithoutAFrontmostAppDoNotPassThrough() {
        let hiddenOnly = AppException(bundleIdentifier: "com.example.hidden", hide: .always)
        let matcher = HotkeyMatcher(profiles: [profile()], exceptions: [hiddenOnly, vm])
        for frontmost in ["com.example.hidden", nil] as [String?] {
            var state = HotkeyMatcher.State()
            state.frontmostBundleID = frontmost
            #expect(!matcher.isPassthrough(state))
            #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: .maskAlternate), state: &state)
                == .init(swallow: true, event: .open(profileID: "all", reverse: false)))
        }
    }

    @Test func anOpenSwitcherKeepsItsKeysWhenAnIgnoringAppBecomesFrontmost() {
        let matcher = HotkeyMatcher(profiles: [profile()], exceptions: [vm])
        var state = opened(matcher)
        state.frontmostBundleID = "com.example.vm"
        #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: .maskAlternate), state: &state)
            == .init(swallow: true, event: .next))
        #expect(matcher.handle(.init(type: .flagsChanged, flags: []), state: &state)
            == .init(swallow: false, event: .modifiersReleased))
        // …and the trigger's keyUp is still owned after closing.
        state.isSwitcherOpen = false
        matcher.close(state: &state)
        #expect(matcher.handle(.init(type: .keyUp, keyCode: KeyCode.tab), state: &state) == .init(swallow: true))
    }

    @Test func builtInDefaultsPassThroughForVirtualMachines() {
        let matcher = HotkeyMatcher(profiles: AppSettings.defaults.profiles, exceptions: AppSettings.defaults.appExceptions)
        for bundleID in ["com.vmware.fusion", "com.parallels.desktop.console", "com.utmapp.UTM", "com.microsoft.rdc.macos"] {
            var state = HotkeyMatcher.State()
            state.frontmostBundleID = bundleID
            #expect(matcher.handle(.init(type: .keyDown, keyCode: KeyCode.tab, flags: .maskAlternate), state: &state)
                == .init(swallow: false), "\(bundleID)")
        }
    }

    @Test @MainActor func managerAcceptsExceptionsWithoutInstallingATap() {
        let manager = HotkeyManager()
        manager.update(exceptions: [vm])
        manager.update(profiles: [profile()])
        #expect(manager.frontmostBundleID == nil) // only observed once started
        manager.stop()
    }

    @Test @MainActor func managerConfigurationAndStopDoNotInstallATap() {
        let manager = HotkeyManager()
        manager.update(profiles: [profile()])
        #expect(!manager.isSwitcherOpen)
        #expect(manager.openProfileID == nil)
        manager.openProfileID = "all"
        manager.stop()
        manager.stop()
        #expect(!manager.isSwitcherOpen)
        #expect(manager.openProfileID == nil)
    }
}
