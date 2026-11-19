// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// Read-only WindowServer queries: connection, Spaces, displays.

import CoreGraphics
import Foundation
import VitrinPrivateC

public enum SkyLight {
    public typealias ConnectionID = CGSConnectionID
    public typealias SpaceID = CGSSpaceID

    /// This process's main WindowServer connection, or `nil` if unavailable.
    public static var mainConnectionID: ConnectionID? {
        guard let fn = PrivateAPI.function(.mainConnectionID, as: VPMainConnectionIDFn.self) else { return nil }
        let cid = fn()
        return cid != 0 ? cid : nil
    }

    // MARK: Spaces of windows

    public struct SpaceMask: OptionSet, Sendable, Hashable {
        public let rawValue: Int32
        public init(rawValue: Int32) { self.rawValue = rawValue }

        public static let includesCurrent = SpaceMask(rawValue: Int32(VPSpaceMaskIncludesCurrent))
        public static let includesOthers = SpaceMask(rawValue: Int32(VPSpaceMaskIncludesOthers))
        public static let includesUser = SpaceMask(rawValue: Int32(VPSpaceMaskIncludesUser))
        /// Visible Spaces only.
        public static let current: SpaceMask = [.includesUser, .includesCurrent]
        public static let others: SpaceMask = [.includesOthers, .includesCurrent]
        public static let all: SpaceMask = [.includesUser, .includesOthers, .includesCurrent]
    }

    /// Spaces `windowID` is on (several if it's on all Spaces). `nil` if the query is unavailable.
    public static func spaces(forWindow windowID: CGWindowID, mask: SpaceMask = .all) -> [SpaceID]? {
        spaces(forWindows: [windowID], mask: mask)
    }

    /// The union of the Spaces of `windowIDs`. (The API does not report per-window results.)
    public static func spaces(forWindows windowIDs: [CGWindowID], mask: SpaceMask = .all) -> [SpaceID]? {
        guard let fn = PrivateAPI.function(.copySpacesForWindows, as: VPCopySpacesForWindowsFn.self),
              let cid = mainConnectionID else { return nil }
        if windowIDs.isEmpty { return [] } // SkyLight returns NULL for an empty list
        let ids = windowIDs.map { NSNumber(value: $0) } as CFArray
        guard let array = fn(cid, mask.rawValue, ids)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return array.map(\.uint64Value)
    }

    // MARK: Displays & Spaces

    public enum SpaceType: Sendable, Hashable {
        case user
        case system
        case fullscreen
        case other(Int32)

        init(rawValue: Int32) {
            switch Int(rawValue) {
            case VPSpaceTypeUser: self = .user
            case VPSpaceTypeSystem: self = .system
            case VPSpaceTypeFullscreen: self = .fullscreen
            default: self = .other(rawValue)
            }
        }
    }

    public struct ManagedSpace: Sendable, Hashable {
        public let id: SpaceID
        public let type: SpaceType
        public let uuid: String?
    }

    public struct ManagedDisplay: Sendable, Hashable {
        /// Display UUID, or `"Main"` when "Displays have separate Spaces" is off (then there is one entry for all displays).
        public let identifier: String
        public let currentSpaceID: SpaceID?
        /// In Mission Control order.
        public let spaces: [ManagedSpace]
    }

    /// Every display with its Spaces. `nil` if the query is unavailable.
    public static func managedDisplays() -> [ManagedDisplay]? {
        guard let fn = PrivateAPI.function(.copyManagedDisplaySpaces, as: VPCopyManagedDisplaySpacesFn.self),
              let cid = mainConnectionID,
              let displays = fn(cid)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return displays.compactMap { display in
            guard let identifier = display["Display Identifier"] as? String else { return nil }
            let current = (display["Current Space"] as? [String: Any]).flatMap(managedSpace)
            let spaces = (display["Spaces"] as? [[String: Any]] ?? []).compactMap(managedSpace)
            return ManagedDisplay(identifier: identifier, currentSpaceID: current?.id, spaces: spaces)
        }
    }

    private static func managedSpace(_ dictionary: [String: Any]) -> ManagedSpace? {
        guard let id = (dictionary["id64"] as? NSNumber ?? dictionary["ManagedSpaceID"] as? NSNumber)?.uint64Value else { return nil }
        let type = (dictionary["type"] as? NSNumber).map { SpaceType(rawValue: $0.int32Value) } ?? .user
        return ManagedSpace(id: id, type: type, uuid: dictionary["uuid"] as? String)
    }

    /// The visible Space on the display with UUID `displayIdentifier`.
    public static func currentSpace(onDisplay displayIdentifier: String) -> SpaceID? {
        guard let fn = PrivateAPI.function(.managedDisplayGetCurrentSpace, as: VPManagedDisplayGetCurrentSpaceFn.self),
              let cid = mainConnectionID else { return nil }
        let space = fn(cid, displayIdentifier as CFString)
        return space != 0 ? space : nil
    }

    /// The visible Space of every display.
    public static func currentSpaces() -> Set<SpaceID>? {
        managedDisplays().map { Set($0.compactMap(\.currentSpaceID)) }
    }

    /// The Space of the display with keyboard focus.
    public static func activeSpace() -> SpaceID? {
        guard let fn = PrivateAPI.function(.getActiveSpace, as: VPGetActiveSpaceFn.self),
              let cid = mainConnectionID else { return nil }
        let space = fn(cid)
        return space != 0 ? space : nil
    }

    /// UUID of the display whose menu bar is active.
    public static func activeMenuBarDisplayIdentifier() -> String? {
        guard let fn = PrivateAPI.function(.copyActiveMenuBarDisplayIdentifier, as: VPCopyActiveMenuBarDisplayIdentifierFn.self),
              let cid = mainConnectionID else { return nil }
        return fn(cid)?.takeRetainedValue() as String?
    }

    /// UUID of the display that owns `space`.
    public static func displayIdentifier(forSpace space: SpaceID) -> String? {
        guard let fn = PrivateAPI.function(.copyManagedDisplayForSpace, as: VPCopyManagedDisplayForSpaceFn.self),
              let cid = mainConnectionID else { return nil }
        return fn(cid, space)?.takeRetainedValue() as String?
    }

    public static func spaceType(_ space: SpaceID) -> SpaceType? {
        guard let fn = PrivateAPI.function(.spaceGetType, as: VPSpaceGetTypeFn.self),
              let cid = mainConnectionID else { return nil }
        return SpaceType(rawValue: fn(cid, space))
    }

    /// The UUID string SkyLight uses for `displayID` (public CoreGraphics API; here for convenience).
    public static func displayIdentifier(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
