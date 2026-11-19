#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'HELP'
Usage: scripts/make-dmg.sh

Package the existing dist/Vitrin.app as dist/Vitrin-<VERSION>.dmg (UDZO),
volume name Vitrin, with an /Applications shortcut. Also writes
dist/Vitrin-<VERSION>.dmg.sha256 (shasum -a 256 -c compatible).
Build first with scripts/build-app.sh. This does not notarize the app or DMG.
HELP
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *) vitrin_die "Unknown argument: $1 (see --help)." ;;
    esac
done
vitrin_require_macos
for tool in hdiutil codesign shasum; do vitrin_require "$tool"; done
version=$(vitrin_version "$REPO_ROOT")
app="$REPO_ROOT/dist/Vitrin.app"
[ -d "$app" ] || vitrin_die 'dist/Vitrin.app is missing. Run scripts/build-app.sh first.'
codesign --verify --deep --strict "$app" || vitrin_die 'The app signature is invalid; rebuild before packaging.'
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[ "$app_version" = "$version" ] || vitrin_die 'App version differs from VERSION; rebuild before packaging.'
stage=$(mktemp -d "$REPO_ROOT/dist/.make-dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/volume"
ditto --noqtn "$app" "$stage/volume/Vitrin.app"
ln -s /Applications "$stage/volume/Applications"
hdiutil create -volname Vitrin -srcfolder "$stage/volume" -format UDZO \
    -ov "$stage/Vitrin-$version.dmg"
hdiutil verify "$stage/Vitrin-$version.dmg"
mv -f "$stage/Vitrin-$version.dmg" "$REPO_ROOT/dist/Vitrin-$version.dmg"
cd "$REPO_ROOT/dist"
shasum -a 256 "Vitrin-$version.dmg" > "$stage/checksum"
mv -f "$stage/checksum" "Vitrin-$version.dmg.sha256"
printf 'Created %s/dist/Vitrin-%s.dmg and .dmg.sha256\n' "$REPO_ROOT" "$version"
