#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'HELP'
Usage: scripts/install.sh [--prefix <dir>] [--no-launch] [--with-cli]

Build release for the current architecture, gracefully quit a running Vitrin,
and install Vitrin.app to /Applications (fallback: ~/Applications if unwritable).
  --prefix <dir>  Install into this directory; no fallback for an explicit path.
  --no-launch     Install without launching (useful for tests).
  --with-cli      Link vitrin into /usr/local/bin or ~/.local/bin.
  --help          Show this help.
  VITRIN_CLI_BIN_DIR overrides the CLI directory (including for prefix tests).

Requires Command Line Tools with Swift 6+: xcode-select --install
Respects build-app.sh's VITRIN_SCRATCH_PATH, VITRIN_SIGN_IDENTITY, and
VITRIN_SIGN_KEYCHAIN. Install a stable certificate with create-signing-cert.sh
first to keep the same signing identity on subsequent local builds.
HELP
}

prefix=
launch=true
with_cli=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            [ "$#" -ge 2 ] && [ -n "$2" ] || vitrin_die '--prefix requires a directory.'
            prefix=$2; shift 2 ;;
        --with-cli) with_cli=true; shift ;;
        --no-launch) launch=false; shift ;;
        -h|--help) usage; exit 0 ;;
        *) vitrin_die "Unknown argument: $1 (see --help)." ;;
    esac
done
vitrin_require_macos
xcode-select -p >/dev/null 2>&1 || vitrin_die 'Command Line Tools are missing. Run: xcode-select --install'
vitrin_require swift
if [ -z "$prefix" ]; then
    prefix=/Applications
    if [ ! -d "$prefix" ] || [ ! -w "$prefix" ] ||
        { [ -e "$prefix/Vitrin.app" ] && [ ! -w "$prefix/Vitrin.app" ]; }; then
        prefix="$HOME/Applications"
        printf 'Using writable fallback: %s\n' "$prefix"
    fi
fi
mkdir -p "$prefix" || vitrin_die "Cannot create installation directory: $prefix"
prefix=$(cd "$prefix" && pwd)
[ -w "$prefix" ] || vitrin_die "Installation directory is not writable: $prefix"
"$SCRIPT_DIR/build-app.sh" --arch native

vitrin_quit

stage=$(mktemp -d "$prefix/.vitrin-install.XXXXXX")
trap 'rm -rf "$stage"' EXIT
# Do not copy inherited download quarantine into a locally built installation.
ditto --noqtn "$REPO_ROOT/dist/Vitrin.app" "$stage/Vitrin.app"
codesign --verify --deep --strict "$stage/Vitrin.app"
destination="$prefix/Vitrin.app"
if [ -e "$destination" ] || [ -L "$destination" ]; then
    mv "$destination" "$stage/previous.app" || vitrin_die "Cannot replace $destination"
fi
if ! mv "$stage/Vitrin.app" "$destination"; then
    if [ -e "$stage/previous.app" ] || [ -L "$stage/previous.app" ]; then
        mv "$stage/previous.app" "$destination"
    fi
    vitrin_die "Cannot install $destination"
fi
printf 'Installed %s\n' "$destination"
if [ "$with_cli" = true ]; then
    cli_dir=$(vitrin_cli_bin_dir)
    mkdir -p "$cli_dir"
    cli_dir=$(cd "$cli_dir" && pwd)
    cli_link="$cli_dir/vitrin"
    if [ -e "$cli_link" ] || [ -L "$cli_link" ]; then
        [ -L "$cli_link" ] && [ "$(readlink "$cli_link")" = "$destination/Contents/MacOS/Vitrin" ] ||
            vitrin_die "Refusing to replace unrelated CLI path: $cli_link"
    else
        ln -s "$destination/Contents/MacOS/Vitrin" "$cli_link"
    fi
    printf 'CLI installed: %s\n' "$cli_link"
    case ":$PATH:" in
        *":$cli_dir:"*) ;;
        *) printf 'Add %s to PATH, for example: export PATH="%s:$PATH"\n' "$cli_dir" "$cli_dir" ;;
    esac
fi
if [ "$launch" = true ]; then
    open "$destination" || vitrin_die "Installed, but could not launch $destination"
else
    printf 'Launch skipped (--no-launch).\n'
fi
