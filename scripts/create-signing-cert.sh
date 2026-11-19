#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'HELP'
Usage: scripts/create-signing-cert.sh [--keychain <path>] [--export-p12 <path>]

Create an RSA-2048, SHA-256 self-signed Code Signing identity named
"Vitrin Self-Signed", valid for 3650 days. Default keychain: login.
An existing identity is left unchanged and exits successfully, including when
--export-p12 is supplied; export when FIRST creating the certificate.

  --keychain <path>   Use this keychain; create it if absent (useful for CI).
  --export-p12 <path> Save the new certificate AND private key; never overwrite.
  --help             Show this help.

Environment:
  VITRIN_KEYCHAIN_PASSWORD  Required for an EXISTING keychain when importing.
                           For a new keychain, generated and printed if unset.
  VITRIN_P12_PASSWORD       Export password; generated and printed if unset.

Existing identities need neither password. Import unlocks the selected keychain
and grants /usr/bin/codesign access with security import -T. No
sudo, trust-store changes, or GUI password prompts are used. For login, supply
its current password through VITRIN_KEYCHAIN_PASSWORD before first creation.
Use a dedicated --keychain for unattended builds to avoid the login keychain.
For signing, that keychain must also be in the user's keychain search list;
--keychain only restricts identity lookup, as documented in man codesign.

Trust: a self-signed identity does NOT need "Always Trust" for codesign signing
or strict signature/DR verification. security find-identity may list it as
CSSMERR_TP_NOT_TRUSTED and omit it from -v output; that is expected. This does
not confer Gatekeeper/Developer ID trust or notarization. See Apple TN2206:
https://developer.apple.com/library/archive/technotes/tn2206/

IMPORTANT: keep the original certificate/private key (the exported P12) for
every release. A newly generated certificate with the same name will change
the designated requirement and may reset privacy permissions.

CI import (VITRIN_CERT_P12_BASE64 / VITRIN_CERT_P12_PASSWORD are secrets):
  See the implementation report for a complete temporary-keychain sequence.
  Build with VITRIN_SIGN_KEYCHAIN=<path> and VITRIN_SIGN_IDENTITY='Vitrin Self-Signed'.
HELP
}

keychain=
export_path=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --keychain|--export-p12)
            [ "$#" -ge 2 ] && [ -n "$2" ] || vitrin_die "$1 requires a path."
            case "$1" in --keychain) keychain=$2 ;; --export-p12) export_path=$2 ;; esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) vitrin_die "Unknown argument: $1 (see --help)." ;;
    esac
done
vitrin_require_macos
vitrin_require security
# macOS's LibreSSL and OpenSSL 3 both support the explicit P12 algorithms below.
vitrin_require openssl
if [ -z "$keychain" ]; then
    keychain="$HOME/Library/Keychains/login.keychain-db"
    [ -f "$keychain" ] || vitrin_die 'Login keychain not found; specify --keychain <path>.'
fi
case "$keychain" in /*) ;; *) keychain="$PWD/$keychain" ;; esac
# security may append -db when creating a keychain without that suffix.
if [ ! -f "$keychain" ] && [ -f "$keychain-db" ]; then keychain="$keychain-db"; fi
if [ -f "$keychain" ]; then
    identities=$(security find-identity -p codesigning "$keychain")
    if printf '%s\n' "$identities" | awk '/"Vitrin Self-Signed"/ { found=1 } END { exit !found }'; then
        printf 'Identity Vitrin Self-Signed already exists in %s; unchanged.\n' "$keychain"
        if [ -n "$export_path" ]; then
            printf 'P12 export skipped: --export-p12 applies only when creating a new identity.\n'
        fi
        exit 0
    fi
    if security find-certificate -c 'Vitrin Self-Signed' "$keychain" >/dev/null 2>&1; then
        vitrin_die 'Certificate exists without a usable Code Signing identity; restore its original P12 instead of replacing it.'
    fi
    [ -n "${VITRIN_KEYCHAIN_PASSWORD:-}" ] ||
        vitrin_die 'Set VITRIN_KEYCHAIN_PASSWORD to this existing keychain password (avoids interactive prompts).'
fi
if [ -n "$export_path" ]; then
    case "$export_path" in /*) ;; *) export_path="$PWD/$export_path" ;; esac
    [ ! -e "$export_path" ] && [ ! -L "$export_path" ] || vitrin_die "Refusing to overwrite $export_path"
    [ -d "$(dirname "$export_path")" ] || vitrin_die 'The P12 export parent directory must already exist.'
fi

umask 077
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/vitrin-cert.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT
keychain_password=${VITRIN_KEYCHAIN_PASSWORD:-}
if [ ! -f "$keychain" ]; then
    [ -d "$(dirname "$keychain")" ] || vitrin_die 'The keychain parent directory must already exist.'
    if [ -z "$keychain_password" ]; then
        keychain_password=$(openssl rand -hex 24)
        printf 'Generated keychain password (save securely): %s\n' "$keychain_password"
    fi
    security create-keychain -p "$keychain_password" "$keychain" || vitrin_die 'Could not create keychain.'
    if [ ! -f "$keychain" ] && [ -f "$keychain-db" ]; then keychain="$keychain-db"; fi
    # Limit this setting to a keychain we created; do not change login settings.
    security set-keychain-settings -lut 21600 "$keychain"
fi
security unlock-keychain -p "$keychain_password" "$keychain" || vitrin_die 'Could not unlock keychain; check VITRIN_KEYCHAIN_PASSWORD.'

cat > "$temp_dir/openssl.cnf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = code_signing
prompt = no
[subject]
CN = Vitrin Self-Signed
O = Vitrin
[code_signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
CONFIG
openssl req -new -newkey rsa:2048 -nodes -x509 -sha256 -days 3650 \
    -config "$temp_dir/openssl.cnf" -keyout "$temp_dir/key.pem" \
    -out "$temp_dir/cert.pem" > "$temp_dir/openssl.log" 2>&1 ||
    vitrin_die 'OpenSSL failed to create the self-signed certificate.'
p12_password=${VITRIN_P12_PASSWORD:-}
if [ -z "$p12_password" ]; then
    p12_password=$(openssl rand -hex 24)
    if [ -n "$export_path" ]; then
        printf 'Generated P12 password (save as VITRIN_CERT_P12_PASSWORD): %s\n' "$p12_password"
    fi
fi
export VITRIN_TEMP_P12_PASSWORD="$p12_password"
# Explicit legacy-compatible algorithms allow security import with either the
# system LibreSSL or Homebrew OpenSSL 3; no global OpenSSL configuration needed.
openssl pkcs12 -export -inkey "$temp_dir/key.pem" -in "$temp_dir/cert.pem" \
    -name 'Vitrin Self-Signed' -out "$temp_dir/identity.p12" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout env:VITRIN_TEMP_P12_PASSWORD
security import "$temp_dir/identity.p12" -k "$keychain" -f pkcs12 \
    -P "$p12_password" -T /usr/bin/codesign || vitrin_die 'Could not import signing identity.'
# -T attaches a codesign ACL, but on current macOS the key's partition list must
# also allow codesign, otherwise every signing shows a keychain prompt (and
# unattended builds hang). `set-key-partition-list -l` matches the key's print
# name, which macOS sets to "Imported Private Key" regardless of the P12
# friendlyName, so only apply it when that name is unambiguous.
key_print_name='Imported Private Key'
key_count=$(security dump-keychain "$keychain" 2>/dev/null |
    awk 'BEGIN{RS="keychain: "} /class: 0x00000010/' |
    grep -c "0x00000001 <blob>=\"$key_print_name\"" || true)
if [ "$key_count" = "1" ]; then
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
        -l "$key_print_name" -k "$keychain_password" "$keychain" >/dev/null ||
        vitrin_die 'Could not grant codesign access to the imported key (set-key-partition-list).'
    printf 'Granted codesign access to the Vitrin key (no keychain prompts when signing).\n'
else
    printf 'WARNING: %s keys named "%s" exist in %s; not changing partition lists automatically.\n' \
        "$key_count" "$key_print_name" "$keychain" >&2
    printf 'codesign may show a keychain prompt; choose "Always Allow" once.\n' >&2
fi
unset VITRIN_TEMP_P12_PASSWORD
if [ -n "$export_path" ]; then
    # Noclobber also protects against a file created since argument validation.
    (set -o noclobber; cat "$temp_dir/identity.p12" > "$export_path") ||
        vitrin_die "Could not write P12 export: $export_path"
    printf 'Exported certificate and private key: %s\n' "$export_path"
fi
printf 'Created Vitrin Self-Signed in %s\n' "$keychain"
printf 'Build with VITRIN_SIGN_KEYCHAIN="%s" (no trust-store changes needed).\n' "$keychain"
printf 'The signing keychain must be on the user search list (see --help and man codesign).\n'
