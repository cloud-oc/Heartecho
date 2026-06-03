#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION_VALUE="${VERSION:-}"
OUTPUT_DIR="$ROOT_DIR/build/pkg"
PACKAGE_PATH=""
DMG_PATH=""
STAGING_DIR=""
VOLUME_NAME=""

if [ -z "$VERSION_VALUE" ]; then
    if [ -f "$ROOT_DIR/VERSION" ]; then
        VERSION_VALUE="$(sed -n '1p' "$ROOT_DIR/VERSION" | tr -d '[:space:]')"
    else
        VERSION_VALUE="0.1.0"
    fi
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --version\n' >&2; exit 64; }
            VERSION_VALUE="$1"
            ;;
        --package)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --package\n' >&2; exit 64; }
            PACKAGE_PATH="$1"
            ;;
        --output)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --output\n' >&2; exit 64; }
            DMG_PATH="$1"
            ;;
        --staging-dir)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --staging-dir\n' >&2; exit 64; }
            STAGING_DIR="$1"
            ;;
        --volume-name)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --volume-name\n' >&2; exit 64; }
            VOLUME_NAME="$1"
            ;;
        --help|-h)
            printf 'Usage: %s [--version VERSION] [--package PKG] [--output DMG] [--staging-dir DIR] [--volume-name NAME]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

[ -n "$VERSION_VALUE" ] || { printf 'Version must not be empty.\n' >&2; exit 64; }

if [ -z "$PACKAGE_PATH" ]; then
    PACKAGE_PATH="$OUTPUT_DIR/Heartecho-Distribution-$VERSION_VALUE.pkg"
fi
if [ -z "$DMG_PATH" ]; then
    DMG_PATH="$OUTPUT_DIR/Heartecho-$VERSION_VALUE.dmg"
fi
if [ -z "$STAGING_DIR" ]; then
    STAGING_DIR="$ROOT_DIR/build/dmg/Heartecho-$VERSION_VALUE"
fi
if [ -z "$VOLUME_NAME" ]; then
    VOLUME_NAME="Heartecho $VERSION_VALUE"
fi

[ -f "$PACKAGE_PATH" ] || { printf 'Missing distribution package: %s\n' "$PACKAGE_PATH" >&2; exit 1; }
command -v hdiutil >/dev/null 2>&1 || { printf 'hdiutil is required to build a DMG.\n' >&2; exit 1; }

DMG_DIR="$(dirname "$DMG_PATH")"
mkdir -p "$DMG_DIR" "$(dirname "$STAGING_DIR")"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

cp "$PACKAGE_PATH" "$STAGING_DIR/Install Heartecho.pkg"
cat >"$STAGING_DIR/ReadMe.txt" <<EOF
Heartecho $VERSION_VALUE

Open "Install Heartecho.pkg" to install or uninstall Heartecho.

This installer manages:
- /Applications/Heartecho.app
- /Library/Audio/Plug-Ins/HAL/Heartecho.driver
- /Library/Application Support/Heartecho/HeartechoHelper
- /Library/LaunchAgents/com.heartecho.Heartecho.Helper.plist

Heartecho installs system audio components. Only install releases from the official GitHub Releases page.
EOF

hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG_PATH"

printf 'Built %s\n' "$DMG_PATH"
printf '%s\n' "- package: $PACKAGE_PATH"
printf '%s\n' "- volume: $VOLUME_NAME"
