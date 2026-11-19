// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// VitrinCore is the pure model layer: window model, shortcut profiles, settings and the config
// store. It depends on Foundation + CoreGraphics value types only (no AppKit UI), so every type here
// is `Sendable` and can be unit-tested without a WindowServer session.

public enum VitrinCore {
    public static let version = "0.1.0"
}
