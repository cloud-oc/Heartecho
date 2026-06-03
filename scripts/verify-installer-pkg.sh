#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PACKAGE_PATH="${1:-$ROOT_DIR/build/pkg/Heartecho-0.1.0.pkg}"
EXPANDED_DIR="$ROOT_DIR/build/pkg/expanded-verify"

[ -f "$PACKAGE_PATH" ] || { printf 'Missing package: %s\n' "$PACKAGE_PATH" >&2; exit 1; }

PAYLOAD_OUTPUT="$(pkgutil --payload-files "$PACKAGE_PATH")"

rm -rf "$EXPANDED_DIR"
pkgutil --expand "$PACKAGE_PATH" "$EXPANDED_DIR" >/dev/null

PACKAGE_INFO="$EXPANDED_DIR/PackageInfo"
[ -f "$PACKAGE_INFO" ] || { printf 'Missing expanded PackageInfo for %s\n' "$PACKAGE_PATH" >&2; exit 1; }
[ -f "$EXPANDED_DIR/Scripts/preinstall" ] || { printf 'Package is missing preinstall script.\n' >&2; exit 1; }
[ -f "$EXPANDED_DIR/Scripts/postinstall" ] || { printf 'Package is missing postinstall script.\n' >&2; exit 1; }
[ -f "$EXPANDED_DIR/Scripts/postuninstall" ] || { printf 'Package is missing postuninstall script.\n' >&2; exit 1; }

sh -n "$EXPANDED_DIR/Scripts/preinstall"
sh -n "$EXPANDED_DIR/Scripts/postinstall"
sh -n "$EXPANDED_DIR/Scripts/postuninstall"

if printf '%s\n' "$PAYLOAD_OUTPUT" | grep -q '/\._'; then
    printf 'Warning: package payload contains AppleDouble metadata files from local extended attributes.\n' >&2
fi

grep -q 'identifier="com.heartecho.Heartecho.pkg"' "$PACKAGE_INFO" || {
    printf 'Unexpected or missing package identifier in %s\n' "$PACKAGE_PATH" >&2
    exit 1
}

printf '%s\n' "$PAYLOAD_OUTPUT" | grep -q '^\./Applications/Heartecho.app/Contents/MacOS/Heartecho$' || {
    printf 'Package is missing Heartecho.app executable payload.\n' >&2
    exit 1
}

printf '%s\n' "$PAYLOAD_OUTPUT" | grep -q '^\./Library/Audio/Plug-Ins/HAL/Heartecho.driver/Contents/MacOS/HeartechoHALDriver$' || {
    printf 'Package is missing HAL driver payload.\n' >&2
    exit 1
}

printf '%s\n' "$PAYLOAD_OUTPUT" | grep -q '^\./Library/Application Support/Heartecho/HeartechoHelper$' || {
    printf 'Package is missing helper payload.\n' >&2
    exit 1
}

printf '%s\n' "$PAYLOAD_OUTPUT" | grep -q '^\./Library/LaunchAgents/com.heartecho.Heartecho.Helper.plist$' || {
    printf 'Package is missing helper LaunchAgent payload.\n' >&2
    exit 1
}

pkgutil --check-signature "$PACKAGE_PATH" >/dev/null 2>&1 || true
printf 'Verified %s\n' "$PACKAGE_PATH"
