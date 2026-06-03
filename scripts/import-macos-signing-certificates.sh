#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
KEYCHAIN_PATH="${SIGNING_KEYCHAIN_PATH:-${RUNNER_TEMP:-$ROOT_DIR/build}/heartecho-signing.keychain-db}"
KEYCHAIN_PASSWORD="${SIGNING_KEYCHAIN_PASSWORD:-}"
APP_CERTIFICATE_BASE64="${DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64:-}"
INSTALLER_CERTIFICATE_BASE64="${DEVELOPER_ID_INSTALLER_CERTIFICATE_BASE64:-}"
APP_CERTIFICATE_PASSWORD="${DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD:-${DEVELOPER_ID_CERTIFICATE_PASSWORD:-}}"
INSTALLER_CERTIFICATE_PASSWORD="${DEVELOPER_ID_INSTALLER_CERTIFICATE_PASSWORD:-${DEVELOPER_ID_CERTIFICATE_PASSWORD:-}}"

if [ -z "$KEYCHAIN_PASSWORD" ]; then
    KEYCHAIN_PASSWORD="$(uuidgen 2>/dev/null || date +%s)"
fi

[ -n "$APP_CERTIFICATE_BASE64" ] || { printf 'Missing DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64.\n' >&2; exit 64; }
[ -n "$INSTALLER_CERTIFICATE_BASE64" ] || { printf 'Missing DEVELOPER_ID_INSTALLER_CERTIFICATE_BASE64.\n' >&2; exit 64; }
[ -n "$APP_CERTIFICATE_PASSWORD" ] || { printf 'Missing DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD or DEVELOPER_ID_CERTIFICATE_PASSWORD.\n' >&2; exit 64; }
[ -n "$INSTALLER_CERTIFICATE_PASSWORD" ] || { printf 'Missing DEVELOPER_ID_INSTALLER_CERTIFICATE_PASSWORD or DEVELOPER_ID_CERTIFICATE_PASSWORD.\n' >&2; exit 64; }

decode_base64() {
    value="$1"
    output="$2"

    if printf '%s' "$value" | base64 --decode >"$output" 2>/dev/null; then
        return
    fi
    printf '%s' "$value" | base64 -D >"$output"
}

mkdir -p "$(dirname "$KEYCHAIN_PATH")" "$ROOT_DIR/build/signing"
APP_CERTIFICATE_PATH="$ROOT_DIR/build/signing/developer-id-application.p12"
INSTALLER_CERTIFICATE_PATH="$ROOT_DIR/build/signing/developer-id-installer.p12"

decode_base64 "$APP_CERTIFICATE_BASE64" "$APP_CERTIFICATE_PATH"
decode_base64 "$INSTALLER_CERTIFICATE_BASE64" "$INSTALLER_CERTIFICATE_PATH"

rm -f "$KEYCHAIN_PATH"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

security import "$APP_CERTIFICATE_PATH" -P "$APP_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
security import "$INSTALLER_CERTIFICATE_PATH" -P "$INSTALLER_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

EXISTING_KEYCHAINS="$(security list-keychains -d user | sed 's/[ "]//g' || true)"
security list-keychains -d user -s "$KEYCHAIN_PATH" $EXISTING_KEYCHAINS
security default-keychain -s "$KEYCHAIN_PATH"

rm -f "$APP_CERTIFICATE_PATH" "$INSTALLER_CERTIFICATE_PATH"

printf 'Imported Developer ID signing certificates\n'
printf '%s\n' "- keychain: $KEYCHAIN_PATH"
security find-identity -v -p codesigning "$KEYCHAIN_PATH"
security find-identity -v -p basic "$KEYCHAIN_PATH" | grep 'Developer ID Installer' || true
