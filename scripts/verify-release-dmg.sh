#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION_VALUE="${VERSION:-}"
DMG_PATH="${1:-}"
MOUNT_DIR="$ROOT_DIR/build/dmg/verify-mount"
MOUNTED=0

if [ -z "$VERSION_VALUE" ]; then
    if [ -f "$ROOT_DIR/VERSION" ]; then
        VERSION_VALUE="$(sed -n '1p' "$ROOT_DIR/VERSION" | tr -d '[:space:]')"
    else
        VERSION_VALUE="0.1.0"
    fi
fi

if [ -z "$DMG_PATH" ]; then
    DMG_PATH="$ROOT_DIR/build/pkg/Heartecho-$VERSION_VALUE.dmg"
fi

[ -f "$DMG_PATH" ] || { printf 'Missing DMG: %s\n' "$DMG_PATH" >&2; exit 1; }
command -v hdiutil >/dev/null 2>&1 || { printf 'hdiutil is required to verify a DMG.\n' >&2; exit 1; }

cleanup() {
    if [ "$MOUNTED" -eq 1 ]; then
        hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

hdiutil verify "$DMG_PATH" >/dev/null
hdiutil imageinfo "$DMG_PATH" >/dev/null

rm -rf "$MOUNT_DIR"
mkdir -p "$MOUNT_DIR"
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" >/dev/null
MOUNTED=1

[ -f "$MOUNT_DIR/Install Heartecho.pkg" ] || { printf 'DMG is missing Install Heartecho.pkg.\n' >&2; exit 1; }
[ -f "$MOUNT_DIR/ReadMe.txt" ] || { printf 'DMG is missing ReadMe.txt.\n' >&2; exit 1; }

"$ROOT_DIR/scripts/verify-distribution-product.sh" "$MOUNT_DIR/Install Heartecho.pkg" >/dev/null

printf 'Verified %s\n' "$DMG_PATH"
