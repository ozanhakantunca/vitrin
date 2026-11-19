#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
usage() {
    cat <<'HELP'
Usage: scripts/uninstall.sh [--prefix <dir>] [--purge-config]

Quit Vitrin and remove Vitrin.app plus CLI symlinks pointing to that app.
Default locations: /Applications and ~/Applications. --prefix selects one.
VITRIN_CLI_BIN_DIR selects an additional CLI directory to check.
--purge-config also removes ~/.config/vitrin. Otherwise settings are preserved.
The login keychain is never modified. You may manually remove the
"Vitrin Self-Signed" signing identity in Keychain Access if no longer needed.
--help shows this help.
HELP
}
prefix=
purge=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            [ "$#" -ge 2 ] && [ -n "$2" ] || vitrin_die '--prefix requires a directory.'
            prefix=$2; shift 2 ;;
        --purge-config) purge=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) vitrin_die "Unknown argument: $1 (see --help)." ;;
    esac
done
vitrin_require_macos
if [ -n "$prefix" ]; then
    [ -d "$prefix" ] || vitrin_die "Installation directory not found: $prefix"
    prefixes=("$(cd "$prefix" && pwd)")
else
    prefixes=(/Applications "$HOME/Applications")
fi
# Verify the bundle identity before removing anything.
for directory in "${prefixes[@]}"; do
    app="$directory/Vitrin.app"
    if [ -e "$app" ] || [ -L "$app" ]; then
        [ ! -L "$app" ] || vitrin_die "Refusing to remove symlinked app: $app"
        identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
        [ "$identifier" = io.github.ozanhakantunca.vitrin ] || vitrin_die "Unexpected bundle identity: $app"
    fi
done
vitrin_quit
for directory in "${prefixes[@]}"; do
    app="$directory/Vitrin.app"
    for bin_dir in /usr/local/bin "$HOME/.local/bin" "${VITRIN_CLI_BIN_DIR:-/usr/local/bin}"; do
        link="$bin_dir/vitrin"
        if [ -L "$link" ] && [ "$(readlink "$link")" = "$app/Contents/MacOS/Vitrin" ]; then
            rm "$link"
            printf 'Removed %s\n' "$link"
        fi
    done
    if [ -d "$app" ]; then
        rm -rf "$app"
        printf 'Removed %s\n' "$app"
    fi
done
if [ "$purge" = true ]; then
    rm -rf "$HOME/.config/vitrin"
    printf 'Removed Vitrin configuration.\n'
fi
printf 'Signing identity preserved; remove manually in Keychain Access if desired.\n'
