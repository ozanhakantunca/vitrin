// swift-tools-version:6.0
// Vitrin — free & open-source window switcher for macOS (GPL-3.0)
import PackageDescription

let package = Package(
    name: "Vitrin",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Vitrin", targets: ["Vitrin"]),
    ],
    targets: [
        // Menu bar app, onboarding, UI. Bundled into Vitrin.app by scripts/build-app.sh
        .executableTarget(
            name: "Vitrin",
            dependencies: ["VitrinCore", "VitrinPrivate", "VitrinSystem"],
            path: "Sources/App"
        ),
        // macOS integration: window tracking (AX + SkyLight), global hotkeys (CGEventTap), thumbnails (ScreenCaptureKit).
        .target(
            name: "VitrinSystem",
            dependencies: ["VitrinCore", "VitrinPrivate"],
            path: "Sources/System"
        ),
        // Pure model layer: window model, shortcut profiles, settings, config store. No AppKit UI.
        .target(
            name: "VitrinCore",
            path: "Sources/Core"
        ),
        // Swift wrappers around private SkyLight / CGS / AX APIs (resolved at runtime, fail-safe).
        .target(
            name: "VitrinPrivate",
            dependencies: ["VitrinPrivateC"],
            path: "Sources/Private"
        ),
        // C declarations (types, function-pointer typedefs) for private APIs.
        .target(
            name: "VitrinPrivateC",
            path: "Sources/PrivateC"
        ),
        .testTarget(
            name: "VitrinCoreTests",
            dependencies: ["VitrinCore"],
            path: "Tests/CoreTests"
        ),
        .testTarget(
            name: "VitrinAppTests",
            dependencies: ["Vitrin"],
            path: "Tests/AppTests"
        ),
        .testTarget(
            name: "VitrinSystemTests",
            dependencies: ["VitrinSystem"],
            path: "Tests/SystemTests"
        ),
        .testTarget(
            name: "VitrinPrivateTests",
            dependencies: ["VitrinPrivate"],
            path: "Tests/PrivateTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
