import Foundation
import Testing
@testable import VitrinCore

@Suite struct ShiftReverseValidationTests {
    private func profile(_ id: String, _ trigger: String?, enabled: Bool = true) -> ShortcutProfile {
        ShortcutProfile(id: id, name: id, isEnabled: enabled, trigger: trigger.flatMap(KeyCombo.init(string:)))
    }

    @Test func flagsATriggerThatIsAnotherTriggerPlusShift() {
        let settings = AppSettings(profiles: [profile("fwd", "option+tab"), profile("rev", "option+shift+tab")])
        #expect(settings.validate() == [.shiftReverseConflict(
            profileID: "rev", otherProfileID: "fwd", trigger: KeyCombo(modifiers: [.option, .shift], key: .tab))])
    }

    @Test func orderAndSemanticKeysDoNotMatter() {
        let settings = AppSettings(profiles: [profile("rev", "shift+option+grave"), profile("app", "option+keyAboveTab")])
        #expect(settings.validate() == [.shiftReverseConflict(
            profileID: "rev", otherProfileID: "app", trigger: KeyCombo(modifiers: [.option, .shift], key: .grave))])
    }

    @Test func unrelatedOrDisabledProfilesAreFine() {
        #expect(AppSettings(profiles: [profile("a", "option+tab"), profile("b", "option+shift+tab", enabled: false)])
            .validate().isEmpty)
        #expect(AppSettings(profiles: [profile("a", "option+tab"), profile("b", "control+shift+tab")]).validate().isEmpty)
        #expect(AppSettings(profiles: [profile("a", "option+tab"), profile("b", "option+shift+space")]).validate().isEmpty)
        #expect(AppSettings(profiles: [profile("a", "option+tab"), profile("b", "option+shift+command+tab")])
            .validate().isEmpty)
        #expect(AppSettings(profiles: [profile("a", nil), profile("b", "option+shift+tab")]).validate().isEmpty)
        // Both already use Shift: that is an exact conflict, reported as such, not as a reverse clash.
        #expect(AppSettings(profiles: [profile("a", "option+shift+tab"), profile("b", "shift+alt+tab")]).validate()
            == [.conflictingTriggers(profileID: "a", otherProfileID: "b", trigger: KeyCombo(modifiers: [.option, .shift], key: .tab))])
    }

    @Test func describesTheClash() {
        let issue = ValidationIssue.shiftReverseConflict(
            profileID: "rev", otherProfileID: "fwd", trigger: KeyCombo(modifiers: [.option, .shift], key: .tab))
        #expect(issue.description.contains("\"rev\"") && issue.description.contains("\"fwd\"")
            && issue.description.contains("option+shift+tab"))
    }
}

@Suite struct BuiltInAppExceptionTests {
    @Test func defaultsIgnoreShortcutsForVMsAndRemoteDesktops() {
        let exceptions = AppSettings.defaults.appExceptions
        #expect(!exceptions.isEmpty)
        #expect(exceptions.allSatisfy { $0.ignoreShortcutsWhenFrontmost && $0.hide == .never })
        let ids = Set(exceptions.map(\.bundleIdentifier))
        #expect(ids.count == exceptions.count)
        for id in ["com.microsoft.rdc.macos", "com.parallels.desktop.console", "com.vmware.fusion", "com.utmapp.UTM",
                   "org.virtualbox.app.VirtualBoxVM", "com.teamviewer.TeamViewer", "com.philandro.anydesk",
                   "tv.parsec.www", "com.moonlight-stream.Moonlight"] {
            #expect(ids.contains(id), "\(id)")
        }
    }

    @Test func missingKeyGetsBuiltInsButAnExplicitEmptyListIsRespected() throws {
        let missing = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(missing.appExceptions == AppException.builtInDefaults)
        let empty = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"appExceptions": []}"#.utf8))
        #expect(empty.appExceptions.isEmpty)
    }

    @Test func plainInitStaysEmpty() {
        #expect(AppSettings().appExceptions.isEmpty)
    }
}
