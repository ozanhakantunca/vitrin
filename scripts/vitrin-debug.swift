#!/usr/bin/env swift
// Sends a debug command to a running Vitrin (requires `defaults write io.github.ozanhakantunca.vitrin debugCommands -bool true`).
// Usage: swift scripts/vitrin-debug.swift open all-windows | next | previous | confirm | cancel | dump
import Foundation

let command = CommandLine.arguments.dropFirst().joined(separator: " ")
guard !command.isEmpty else {
    FileHandle.standardError.write(Data("usage: vitrin-debug.swift <open [profile]|next|previous|confirm|cancel|dump>\n".utf8))
    exit(2)
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("io.github.ozanhakantunca.vitrin.debug"),
    object: command, userInfo: nil, deliverImmediately: true
)
