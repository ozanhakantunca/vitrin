/// Keyboard shortcuts that can move to a Space, in order of preference.
public struct DesktopSwitchPlan: Equatable, Sendable {
    public enum Shortcut: Hashable, Sendable {
        case desktop(number: Int)
        case moveLeft
        case moveRight
    }

    public let shortcut: Shortcut
    public let pressCount: Int

    public static func candidates(
        to targetID: SpaceID,
        in desktops: [Desktop],
        managedDisplayCount: Int,
        activeDisplayIdentifier: String?,
        hasBinding: (Shortcut) -> Bool
    ) -> [Self] {
        guard let target = desktops.first(where: { $0.id == targetID }),
              let current = desktops.first(where: { $0.isCurrent && $0.displayIdentifier == target.displayIdentifier }),
              current.id != target.id,
              target.displayIdentifier == activeDisplayIdentifier
                || (managedDisplayCount == 1 && target.displayIdentifier == "Main") else { return [] }

        var plans: [Self] = []
        // Native Desktop N shortcuts are numbered across displays. Our desktop numbers are display-local.
        if managedDisplayCount == 1, case let .desktop(number) = target.kind, (1...16).contains(number) {
            let shortcut = Shortcut.desktop(number: number)
            if hasBinding(shortcut) {
                plans.append(Self(shortcut: shortcut, pressCount: 1))
            }
        }

        let delta = target.index - current.index
        let shortcut: Shortcut = delta < 0 ? .moveLeft : .moveRight
        if delta != 0, hasBinding(shortcut) {
            plans.append(Self(shortcut: shortcut, pressCount: abs(delta)))
        }
        return plans
    }
}
