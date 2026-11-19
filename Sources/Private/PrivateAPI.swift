// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// Runtime resolution of private symbols. Nothing in VitrinPrivate links against a private framework:
// each symbol is looked up once with dlsym, and every wrapper returns nil / false when its symbol is
// missing, so a future macOS that drops one degrades a feature instead of crashing at launch.

import Darwin
import VitrinPrivateC

public enum PrivateAPI {
    /// The image a symbol is looked up in (before falling back to the global namespace).
    public enum Library: String, Sendable, CaseIterable {
        case skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        case applicationServices = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        case multitouchSupport = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    }

    /// Every private function Vitrin uses.
    public enum Symbol: String, Sendable, CaseIterable {
        case mainConnectionID
        case copySpacesForWindows
        case copyManagedDisplaySpaces
        case managedDisplayGetCurrentSpace
        case getActiveSpace
        case copyActiveMenuBarDisplayIdentifier
        case copyManagedDisplayForSpace
        case spaceGetType
        case setSymbolicHotKeyEnabled
        case isSymbolicHotKeyEnabled
        case getSymbolicHotKeyValue
        case setFrontProcessWithOptions
        case postEventRecordTo
        case spaceSetFrontPSN
        case axUIElementGetWindow
        case axUIElementCreateWithRemoteToken
        case getProcessForPID
        case mtDeviceCreateList
        case mtRegisterContactFrameCallback
        case mtUnregisterContactFrameCallback
        case mtDeviceStart
        case mtDeviceStop
        case mtDeviceIsRunning
        case mtDeviceIsBuiltIn
        case mtDeviceGetDeviceID

        /// Exported names to try, in order. SkyLight's `SLS*` names come first; the legacy `CGS*` aliases
        /// (re-exported by CoreGraphics) are the fallback.
        public var candidates: [String] {
            switch self {
            case .mainConnectionID: return ["SLSMainConnectionID", "CGSMainConnectionID"]
            case .copySpacesForWindows: return ["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"]
            case .copyManagedDisplaySpaces: return ["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"]
            case .managedDisplayGetCurrentSpace: return ["SLSManagedDisplayGetCurrentSpace", "CGSManagedDisplayGetCurrentSpace"]
            case .getActiveSpace: return ["SLSGetActiveSpace", "CGSGetActiveSpace"]
            case .copyActiveMenuBarDisplayIdentifier: return ["SLSCopyActiveMenuBarDisplayIdentifier", "CGSCopyActiveMenuBarDisplayIdentifier"]
            case .copyManagedDisplayForSpace: return ["SLSCopyManagedDisplayForSpace", "CGSCopyManagedDisplayForSpace"]
            case .spaceGetType: return ["SLSSpaceGetType", "CGSSpaceGetType"]
            case .setSymbolicHotKeyEnabled: return ["SLSSetSymbolicHotKeyEnabled", "CGSSetSymbolicHotKeyEnabled"]
            case .isSymbolicHotKeyEnabled: return ["SLSIsSymbolicHotKeyEnabled", "CGSIsSymbolicHotKeyEnabled"]
            case .getSymbolicHotKeyValue: return ["SLSGetSymbolicHotKeyValue", "CGSGetSymbolicHotKeyValue"]
            case .setFrontProcessWithOptions: return ["_SLPSSetFrontProcessWithOptions"]
            case .postEventRecordTo: return ["SLPSPostEventRecordTo"]
            case .spaceSetFrontPSN: return ["SLSSpaceSetFrontPSN", "CGSSpaceSetFrontPSN"]
            case .axUIElementGetWindow: return ["_AXUIElementGetWindow"]
            case .axUIElementCreateWithRemoteToken: return ["_AXUIElementCreateWithRemoteToken"]
            case .getProcessForPID: return ["GetProcessForPID"]
            case .mtDeviceCreateList: return ["MTDeviceCreateList"]
            case .mtRegisterContactFrameCallback: return ["MTRegisterContactFrameCallback"]
            case .mtUnregisterContactFrameCallback: return ["MTUnregisterContactFrameCallback"]
            case .mtDeviceStart: return ["MTDeviceStart"]
            case .mtDeviceStop: return ["MTDeviceStop"]
            case .mtDeviceIsRunning: return ["MTDeviceIsRunning"]
            case .mtDeviceIsBuiltIn: return ["MTDeviceIsBuiltIn"]
            case .mtDeviceGetDeviceID: return ["MTDeviceGetDeviceID"]
            }
        }

        public var library: Library {
            switch self {
            case .axUIElementGetWindow, .axUIElementCreateWithRemoteToken, .getProcessForPID: return .applicationServices
            case .mtDeviceCreateList, .mtRegisterContactFrameCallback, .mtUnregisterContactFrameCallback, .mtDeviceStart,
                 .mtDeviceStop, .mtDeviceIsRunning, .mtDeviceIsBuiltIn, .mtDeviceGetDeviceID:
                return .multitouchSupport
            default: return .skyLight
            }
        }
    }

    /// Diagnostic row for one symbol.
    public struct SymbolAvailability: Sendable, Hashable, CustomStringConvertible {
        public let symbol: Symbol
        /// The exported name that resolved, or `nil` if none did.
        public let resolvedName: String?
        /// Path of the image that actually exports it (may be a re-exporting umbrella's sub-image).
        public let imagePath: String?

        public var isAvailable: Bool { resolvedName != nil }

        public var description: String {
            guard let resolvedName else { return "✗ \(symbol.rawValue) — none of \(symbol.candidates.joined(separator: ", "))" }
            return "✓ \(symbol.rawValue) → \(resolvedName)" + (imagePath.map { " (\($0))" } ?? "")
        }
    }

    /// Which private symbols resolved on this macOS. Log this on launch / attach it to bug reports.
    public static func availabilityReport() -> [SymbolAvailability] {
        Symbol.allCases.map { symbol in
            guard let entry = resolved[symbol], let pointer = UnsafeRawPointer(bitPattern: entry.address) else {
                return SymbolAvailability(symbol: symbol, resolvedName: nil, imagePath: nil)
            }
            var info = Dl_info()
            let image = dladdr(pointer, &info) != 0 && info.dli_fname != nil ? String(cString: info.dli_fname) : nil
            return SymbolAvailability(symbol: symbol, resolvedName: entry.name, imagePath: image)
        }
    }

    /// Multi-line, human-readable version of `availabilityReport()`.
    public static func availabilityReportText() -> String {
        availabilityReport().map(\.description).joined(separator: "\n")
    }

    public static var allSymbolsAvailable: Bool {
        resolved.count == Symbol.allCases.count
    }

    public static func isAvailable(_ symbol: Symbol) -> Bool {
        resolved[symbol] != nil
    }

    // MARK: Resolution (once, lazily, thread-safe via `static let`)

    private struct Entry: Sendable {
        let name: String
        let address: UInt
    }

    private static let resolved: [Symbol: Entry] = {
        // dlopen of an already-loaded system image just returns its handle; nil if the path vanished.
        var handles: [Library: UInt] = [:]
        for library in Library.allCases {
            if let handle = dlopen(library.rawValue, RTLD_LAZY | RTLD_LOCAL) {
                handles[library] = UInt(bitPattern: handle)
            }
        }
        let globalNamespace = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT

        var table: [Symbol: Entry] = [:]
        for symbol in Symbol.allCases {
            let searchOrder = [handles[symbol.library].flatMap { UnsafeMutableRawPointer(bitPattern: $0) }, globalNamespace]
            outer: for name in symbol.candidates {
                for handle in searchOrder {
                    if let pointer = dlsym(handle, name) {
                        table[symbol] = Entry(name: name, address: UInt(bitPattern: pointer))
                        break outer
                    }
                }
            }
        }
        return table
    }()

    /// The resolved symbol reinterpreted as the C function-pointer type `T` (one of the `VP*Fn` typedefs).
    static func function<T>(_ symbol: Symbol, as type: T.Type) -> T? {
        guard let entry = resolved[symbol], let pointer = UnsafeRawPointer(bitPattern: entry.address) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
}
