#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'HELP'
Usage: scripts/build-app.sh [--debug] [--arch native|universal]

Build dist/Vitrin.app from any working directory. Defaults: release, universal.
Universal builds compile arm64 and x86_64 separately and combine them with lipo;
this also works with Command Line Tools alone (Swift 6+ is required).

Environment:
  VITRIN_SCRATCH_PATH    SwiftPM scratch root, default .build (relative to repo).
                        Each architecture uses its own subdirectory.
  VITRIN_SIGN_IDENTITY   Signing name/hash; '-' forces ad-hoc signing.
                        Default: Vitrin Self-Signed if present, otherwise '-'.
  VITRIN_SIGN_KEYCHAIN   Optional keychain containing the signing identity.
                        It must also be on the user's keychain search list
                        (man codesign); this script does not change that list.

Keep the SAME certificate/private key across updates to preserve the designated
requirement. Recreating a certificate with the same name changes that identity.
Ad-hoc signatures do not provide a stable identity across changed binaries.

Phase 0 deliberately leaves hardened runtime OFF: no notarization is performed,
and private SkyLight APIs are loaded with dlopen/dlsym. This avoids adding runtime
restrictions during initial integration. No sandbox or exception entitlements
are needed. Apple-signed SkyLight itself is compatible with library validation;
reassess hardened runtime once the complete switcher flow is tested.
HELP
}

configuration=release
architecture=universal
while [ "$#" -gt 0 ]; do
    case "$1" in
        --debug) configuration=debug; shift ;;
        --arch)
            [ "$#" -ge 2 ] || vitrin_die '--arch requires native or universal.'
            architecture=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) vitrin_die "Unknown argument: $1 (see --help)." ;;
    esac
done
case "$architecture" in native|universal) ;; *) vitrin_die '--arch must be native or universal.' ;; esac
vitrin_require_macos
for tool in swift xcrun lipo codesign security; do vitrin_require "$tool"; done
xcode-select -p >/dev/null 2>&1 || vitrin_die 'Install Command Line Tools: xcode-select --install'
version=$(vitrin_version "$REPO_ROOT")
scratch=${VITRIN_SCRATCH_PATH:-.build}
case "$scratch" in /*) ;; *) scratch="$REPO_ROOT/$scratch" ;; esac
cd "$REPO_ROOT"

# Individual --arch builds avoid SwiftPM's Xcode-dependent universal build path.
if [ "$architecture" = universal ]; then
    architectures=(arm64 x86_64)
else
    native_arch=$(uname -m)
    case "$native_arch" in arm64|x86_64) ;; *) vitrin_die "Unsupported host architecture: $native_arch" ;; esac
    architectures=("$native_arch")
fi
binaries=()
for arch in "${architectures[@]}"; do
    printf 'Building Vitrin: %s / %s\n' "$configuration" "$arch"
    build_args=(--package-path "$REPO_ROOT" --scratch-path "$scratch/$arch" --build-system native --configuration "$configuration" --arch "$arch")
    swift build "${build_args[@]}" --product Vitrin || vitrin_die "Swift build failed for $arch."
    bin_dir=$(swift build "${build_args[@]}" --show-bin-path)
    [ -x "$bin_dir/Vitrin" ] || vitrin_die "Built executable missing: $bin_dir/Vitrin"
    binaries+=("$bin_dir/Vitrin")
done

mkdir -p "$REPO_ROOT/dist"
stage=$(mktemp -d "$REPO_ROOT/dist/.build-app.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/Vitrin.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
if [ "$architecture" = universal ]; then
    lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/Vitrin"
    arch_list=" $(lipo -archs "$app/Contents/MacOS/Vitrin") "
    [[ "$arch_list" = *' arm64 '* ]] && [[ "$arch_list" = *' x86_64 '* ]] ||
        vitrin_die "Universal binary is missing an architecture: $arch_list"
else
    cp "${binaries[0]}" "$app/Contents/MacOS/Vitrin"
fi
chmod 755 "$app/Contents/MacOS/Vitrin"
lipo -info "$app/Contents/MacOS/Vitrin"
build_number=$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || printf '1')
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || build_number=1
sed -e "s/@VERSION@/$version/g" -e "s/@BUILD_NUMBER@/$build_number/g" \
    "$REPO_ROOT/Resources/Info.plist" > "$app/Contents/Info.plist"
if [ -f "$REPO_ROOT/Resources/AppIcon/Vitrin.icns" ]; then
    cp "$REPO_ROOT/Resources/AppIcon/Vitrin.icns" "$app/Contents/Resources/Vitrin.icns"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string Vitrin' "$app/Contents/Info.plist"
fi
for localization in "$REPO_ROOT"/Resources/Localization/*.lproj; do
    [ -d "$localization" ] || continue
    ditto "$localization" "$app/Contents/Resources/$(basename "$localization")"
done
plutil -lint "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

keychain_args=()
if [ -n "${VITRIN_SIGN_KEYCHAIN:-}" ]; then
    [ -f "$VITRIN_SIGN_KEYCHAIN" ] || vitrin_die "Signing keychain not found: $VITRIN_SIGN_KEYCHAIN"
    keychain_args=("$VITRIN_SIGN_KEYCHAIN")
fi
identity=${VITRIN_SIGN_IDENTITY:-}
if [ -z "$identity" ]; then
    # Use all identities, not only -v: a locally self-signed certificate need not
    # be in the user's trust store. codesign verifies its cryptographic validity.
    if [ "${#keychain_args[@]}" -gt 0 ]; then
        identities=$(security find-identity -p codesigning "${keychain_args[0]}")
    else
        identities=$(security find-identity -p codesigning)
    fi
    identity=$(printf '%s\n' "$identities" | awk '/"Vitrin Self-Signed"/ { print $2; exit }')
    identity=${identity:--}
fi
sign_args=(--force --sign "$identity" --identifier io.github.ozanhakantunca.vitrin --timestamp=none)
if [ "${#keychain_args[@]}" -gt 0 ]; then
    sign_args+=(--keychain "${keychain_args[0]}")
fi
if [ "$identity" = - ]; then
    printf 'Signing mode: ad-hoc (-); hardened runtime: off\n'
else
    printf 'Signing mode: certificate (%s); hardened runtime: off\n' "$identity"
fi
codesign "${sign_args[@]}" "$app" || vitrin_die 'Code signing failed. Check the identity, unlocked keychain, user keychain search list, and codesign key access.'
codesign --verify --deep --strict --verbose=2 "$app"
# Replace only after a successful build and signature verification.
rm -rf "$REPO_ROOT/dist/Vitrin.app"
mv "$app" "$REPO_ROOT/dist/Vitrin.app"
printf 'Built %s\n' "$REPO_ROOT/dist/Vitrin.app"
