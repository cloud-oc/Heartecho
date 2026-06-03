#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PACKAGE_PATH="${1:-$ROOT_DIR/build/pkg/Heartecho-Uninstaller-0.1.0.pkg}"
EXPANDED_DIR="$ROOT_DIR/build/pkg/expanded-uninstaller-verify"

[ -f "$PACKAGE_PATH" ] || { printf 'Missing package: %s\n' "$PACKAGE_PATH" >&2; exit 1; }

PAYLOAD_OUTPUT="$(pkgutil --payload-files "$PACKAGE_PATH")"

rm -rf "$EXPANDED_DIR"
pkgutil --expand "$PACKAGE_PATH" "$EXPANDED_DIR" >/dev/null

PACKAGE_INFO="$EXPANDED_DIR/PackageInfo"
[ -f "$PACKAGE_INFO" ] || { printf 'Missing expanded PackageInfo for %s\n' "$PACKAGE_PATH" >&2; exit 1; }
[ -f "$EXPANDED_DIR/Scripts/preinstall" ] || { printf 'Uninstaller package is missing preinstall script.\n' >&2; exit 1; }
[ -f "$EXPANDED_DIR/Scripts/postinstall" ] || { printf 'Uninstaller package is missing postinstall script.\n' >&2; exit 1; }

sh -n "$EXPANDED_DIR/Scripts/preinstall"
sh -n "$EXPANDED_DIR/Scripts/postinstall"

grep -q 'identifier="com.heartecho.Heartecho.uninstaller.pkg"' "$PACKAGE_INFO" || {
    printf 'Unexpected or missing uninstaller package identifier in %s\n' "$PACKAGE_PATH" >&2
    exit 1
}

if [ -n "$PAYLOAD_OUTPUT" ]; then
    printf 'Uninstaller package unexpectedly contains payload files.\n' >&2
    printf '%s\n' "$PAYLOAD_OUTPUT" >&2
    exit 1
fi

pkgutil --check-signature "$PACKAGE_PATH" >/dev/null 2>&1 || true
printf 'Verified %s\n' "$PACKAGE_PATH"
