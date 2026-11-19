#!/usr/bin/env swift
// Sends a debug command to a running Vitrin (requires `defaults write io.github.ozanhakantunca.vitrin debugCommands -bool true`).
// Usage: swift scripts/vitrin-debug.swift open all-windows | next | previous | up | down | left | right | confirm | cancel | dump | desktops | desktop <index>
import Foundation

let command = CommandLine.arguments.dropFirst().joined(separator: " ")
guard !command.isEmpty else {
    FileHandle.standardError.write(Data("usage: vitrin-debug.swift <open [profile]|next|previous|up|down|left|right|confirm|cancel|dump|desktops|desktop index> (desktop index is 0-based)\n".utf8))
    exit(2)
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("io.github.ozanhakantunca.vitrin.debug"),
    object: command, userInfo: nil, deliverImmediately: true
)
