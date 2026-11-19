import Testing
import VitrinCore

struct DesktopSwitchPlanTests {
    private let display = "display-uuid"
    private typealias Shortcut = DesktopSwitchPlan.Shortcut

    private func plans(
        _ kinds: [Desktop.Kind], current: Int?, target: Int,
        active: String? = "display-uuid", displayIdentifier: String = "display-uuid",
        displayCount: Int = 1, bindings: Set<Shortcut>
    ) -> [DesktopSwitchPlan] {
        let desktops = kinds.enumerated().map { index, kind in
            Desktop(id: SpaceID(index), kind: kind, displayIdentifier: displayIdentifier,
                    isCurrent: index == current, index: index)
        }
        return DesktopSwitchPlan.candidates(
            to: SpaceID(target), in: desktops, managedDisplayCount: displayCount,
            activeDisplayIdentifier: active, hasBinding: bindings.contains
        )
    }

    @Test func prefersDesktopNumberWithFullscreenSpacesInterleaved() {
        let result = plans(
            [.desktop(number: 1), .fullscreen, .fullscreen, .desktop(number: 2)],
            current: 0, target: 3, bindings: [.desktop(number: 2), .moveRight]
        )
        #expect(result.map(\.shortcut) == [.desktop(number: 2), .moveRight])
        #expect(result.map(\.pressCount) == [1, 3])
    }

    @Test func sharedMainDisplayDoesNotNeedAnActiveDisplayUUID() {
        let result = plans(
            [.desktop(number: 1), .desktop(number: 2)], current: 0, target: 1,
            active: nil, displayIdentifier: "Main", bindings: [.desktop(number: 2)]
        )
        #expect(result.map(\.shortcut) == [.desktop(number: 2)])
        #expect(result.map(\.pressCount) == [1])
    }

    @Test func multipleManagedDisplaysUseRelativeStepsEvenWithANumberedBinding() {
        let result = plans(
            [.desktop(number: 1), .fullscreen, .desktop(number: 2)], current: 0, target: 2,
            displayCount: 2, bindings: [.desktop(number: 2), .moveRight]
        )
        #expect(result.map(\.shortcut) == [.moveRight])
        #expect(result.map(\.pressCount) == [2])
    }

    @Test func fullscreenTargetsUseRelativeStepsInEitherDirection() {
        let kinds: [Desktop.Kind] = [.desktop(number: 1), .fullscreen, .desktop(number: 2), .fullscreen]
        let left = plans(kinds, current: 3, target: 1, bindings: [.moveLeft, .moveRight])
        let right = plans(kinds, current: 0, target: 3, bindings: [.moveLeft, .moveRight])
        #expect(left.map(\.shortcut) == [.moveLeft])
        #expect(left.map(\.pressCount) == [2])
        #expect(right.map(\.shortcut) == [.moveRight])
        #expect(right.map(\.pressCount) == [3])
    }

    @Test func desktopSeventeenFallsBackAndDesktopSixteenCanJump() {
        let kinds: [Desktop.Kind] = (1...17).map { .desktop(number: $0) }
        let sixteenth = plans(kinds, current: 14, target: 15, bindings: [.desktop(number: 16)])
        let seventeenth = plans(kinds, current: 14, target: 16, bindings: [.desktop(number: 17), .moveRight])
        #expect(sixteenth.map(\.shortcut) == [.desktop(number: 16)])
        #expect(seventeenth.map(\.shortcut) == [.moveRight])
        #expect(seventeenth.map(\.pressCount) == [2])
    }

    @Test func missingNumberedBindingFallsBackToTheRequiredDirection() {
        let kinds: [Desktop.Kind] = [.desktop(number: 1), .fullscreen, .desktop(number: 2)]
        let result = plans(kinds, current: 2, target: 0, bindings: [.moveLeft])
        #expect(result.map(\.shortcut) == [.moveLeft])
        #expect(result.map(\.pressCount) == [2])
        #expect(plans(kinds, current: 2, target: 0, bindings: [.moveRight]).isEmpty)
    }

    @Test func alreadyCurrentAndMissingSpacesHaveNoPlan() {
        let kinds: [Desktop.Kind] = [.desktop(number: 1), .desktop(number: 2)]
        let bindings: Set<Shortcut> = [.desktop(number: 2), .moveRight]
        #expect(plans(kinds, current: 1, target: 1, bindings: bindings).isEmpty)
        #expect(plans(kinds, current: nil, target: 1, bindings: bindings).isEmpty)
        #expect(plans(kinds, current: 0, target: 2, bindings: bindings).isEmpty)
    }

    @Test func anInactiveOrUnknownDisplayHasNoPlan() {
        let kinds: [Desktop.Kind] = [.desktop(number: 1), .desktop(number: 2)]
        let bindings: Set<Shortcut> = [.desktop(number: 2), .moveRight]
        #expect(plans(kinds, current: 0, target: 1, active: "other", displayIdentifier: display,
                      displayCount: 2, bindings: bindings).isEmpty)
        #expect(plans(kinds, current: 0, target: 1, active: nil, bindings: bindings).isEmpty)
    }
}
