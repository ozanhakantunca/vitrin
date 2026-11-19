import Foundation
import Testing
@testable import Vitrin

@Test func semanticVersionComparison() {
    #expect(UpdateLogic.isNewer("0.10.0", than: "0.9.2"))
    #expect(UpdateLogic.isNewer("v1.0.0", than: "1.0.0-rc.1"))
    #expect(!UpdateLogic.isNewer("1.0.0", than: "1.0.0"))
    #expect(UpdateLogic.isNewer("1.0", than: "0.9.9"))
    #expect(!UpdateLogic.isNewer("abc", than: "1.0.0"))
    #expect(!UpdateLogic.isNewer("1.0.0-rc.2", than: "1.0.0-rc.10"))
}

private func release(tag: String, draft: Bool = false, prerelease: Bool = false, dmg: Bool = true) -> Data {
    let assets = dmg ? #"[{"name":"Vitrin-x.dmg","browser_download_url":"https://github.com/o/r/releases/download/\#(tag)/Vitrin.dmg"}]"# : "[]"
    let json = #"{"tag_name":"\#(tag)","draft":\#(draft),"prerelease":\#(prerelease),"html_url":"https://github.com/o/r/releases/tag/\#(tag)","body":"notes","assets":\#(assets)}"#
    return Data(json.utf8)
}

@Test func releaseParsing() {
    let update = UpdateLogic.parseRelease(release(tag: "v0.2.0"), currentVersion: "0.1.0", skippedVersion: nil)
    #expect(update?.version == "0.2.0" && update?.dmgURL != nil)
    #expect(UpdateLogic.parseRelease(release(tag: "v0.2.0", draft: true), currentVersion: "0.1.0", skippedVersion: nil) == nil)
    #expect(UpdateLogic.parseRelease(release(tag: "v0.2.0", prerelease: true), currentVersion: "0.1.0", skippedVersion: nil) != nil)
    #expect(UpdateLogic.parseRelease(release(tag: "v2.0.0", prerelease: true), currentVersion: "1.0.0", skippedVersion: nil) == nil)
    #expect(UpdateLogic.parseRelease(release(tag: "v0.2.0"), currentVersion: "0.1.0", skippedVersion: "0.2.0") == nil)
    #expect(UpdateLogic.parseRelease(release(tag: "v0.1.0"), currentVersion: "0.1.0", skippedVersion: nil) == nil)
    #expect(UpdateLogic.parseRelease(release(tag: "v0.3.0", dmg: false), currentVersion: "0.1.0", skippedVersion: nil)?.dmgURL == nil)
    #expect(UpdateLogic.parseRelease(Data("{}".utf8), currentVersion: "0.1.0", skippedVersion: nil) == nil)
}
