#!/bin/bash
# Shared helpers; callers use macOS /bin/bash 3.2 and set -euo pipefail.

vitrin_die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

vitrin_require_macos() {
    [ "$(uname -s)" = Darwin ] || vitrin_die 'This script requires macOS.'
}

vitrin_require() {
    command -v "$1" >/dev/null 2>&1 || vitrin_die "Required tool not found: $1"
}

vitrin_version() {
    local version
    version=$(tr -d '\r\n' < "$1/VERSION")
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        vitrin_die 'VERSION must contain a numeric major.minor.patch version.'
    printf '%s\n' "$version"
}

vitrin_cli_bin_dir() {
    if [ -n "${VITRIN_CLI_BIN_DIR:-}" ]; then
        printf '%s\n' "$VITRIN_CLI_BIN_DIR"
    elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
        printf '%s\n' /usr/local/bin
    else
        printf '%s\n' "$HOME/.local/bin"
    fi
}

vitrin_quit() {
    local running attempt
    running=$(osascript -l JavaScript -e \
        'ObjC.import("AppKit"); $.NSRunningApplication.runningApplicationsWithBundleIdentifier("io.github.ozanhakantunca.vitrin").count > 0')
    if [ "$running" = true ]; then
        osascript -e 'tell application id "io.github.ozanhakantunca.vitrin" to quit' ||
            vitrin_die 'Vitrin could not quit. Quit it manually and rerun.'
        for ((attempt = 0; attempt < 50; attempt++)); do
            running=$(osascript -l JavaScript -e \
                'ObjC.import("AppKit"); $.NSRunningApplication.runningApplicationsWithBundleIdentifier("io.github.ozanhakantunca.vitrin").count > 0')
            [ "$running" = false ] && break
            sleep 0.2
        done
        [ "$running" = false ] || vitrin_die 'Vitrin is still running. Quit it manually and rerun.'
    fi
}
