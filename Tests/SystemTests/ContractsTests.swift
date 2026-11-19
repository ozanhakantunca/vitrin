import Testing
@testable import VitrinSystem

@Test func hotkeyEventsAreHashable() {
    #expect(HotkeyEvent.next != HotkeyEvent.previous)
}
