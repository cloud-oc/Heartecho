#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUNDLE_DIR="${1:-$ROOT_DIR/build/HAL/Heartecho.driver}"
INFO_PLIST="$BUNDLE_DIR/Contents/Info.plist"
BINARY_PATH="$BUNDLE_DIR/Contents/MacOS/HeartechoHALDriver"
ICON_PATH="$BUNDLE_DIR/Contents/Resources/HeartechoDriver.icns"
ICONSET_DIR="$BUNDLE_DIR/Contents/Resources/HeartechoDriver.iconset"

if [ ! -d "$BUNDLE_DIR" ]; then
    printf 'Missing bundle directory: %s\n' "$BUNDLE_DIR" >&2
    exit 1
fi

if [ ! -f "$INFO_PLIST" ]; then
    printf 'Missing Info.plist: %s\n' "$INFO_PLIST" >&2
    exit 1
fi

if [ ! -x "$BINARY_PATH" ]; then
    printf 'Missing executable binary: %s\n' "$BINARY_PATH" >&2
    exit 1
fi

if [ -d "$BUNDLE_DIR/Contents/MacOS/HeartechoHALDriver.dSYM" ]; then
    printf 'Unexpected dSYM inside HAL bundle MacOS directory\n' >&2
    exit 1
fi

EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
FACTORY_SYMBOL="$(/usr/libexec/PlistBuddy -c 'Print :CFPlugInFactories:4A3D5E5B-73A2-41B7-9B7D-7C3D9BB4E5E1' "$INFO_PLIST")"
ICON_FILE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$INFO_PLIST" 2>/dev/null || true)"

if [ "$EXECUTABLE" != "HeartechoHALDriver" ]; then
    printf 'Unexpected CFBundleExecutable: %s\n' "$EXECUTABLE" >&2
    exit 1
fi

if [ "$IDENTIFIER" != "com.heartecho.Heartecho.Driver" ]; then
    printf 'Unexpected CFBundleIdentifier: %s\n' "$IDENTIFIER" >&2
    exit 1
fi

if [ "$FACTORY_SYMBOL" != "HeartechoHALDriverFactory" ]; then
    printf 'Unexpected factory symbol in Info.plist: %s\n' "$FACTORY_SYMBOL" >&2
    exit 1
fi

if [ "$ICON_FILE" != "HeartechoDriver" ]; then
    printf 'Unexpected or missing CFBundleIconFile: %s\n' "$ICON_FILE" >&2
    exit 1
fi

if [ ! -f "$ICON_PATH" ]; then
    [ -d "$ICONSET_DIR" ] || { printf 'Missing HAL driver icon: %s\n' "$ICON_PATH" >&2; exit 1; }
    [ ! -d "$ICONSET_DIR/HeartechoDriver.iconset" ] || {
        printf 'Unexpected nested HAL driver iconset directory.\n' >&2
        exit 1
    }
    for icon_name in icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png icon_128x128.png icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png icon_512x512.png icon_512x512@2x.png; do
        [ -f "$ICONSET_DIR/$icon_name" ] || {
            printf 'Missing HAL driver iconset image: %s\n' "$icon_name" >&2
            exit 1
        }
    done
fi

if ! nm -gU "$BINARY_PATH" | awk '{ print $NF }' | grep -qx '_HeartechoHALDriverFactory'; then
    printf 'Binary does not export _HeartechoHALDriverFactory\n' >&2
    exit 1
fi

if ! file "$BINARY_PATH" | grep -q 'Mach-O.*dynamically linked shared library'; then
    printf 'Binary is not a Mach-O dynamic library: %s\n' "$BINARY_PATH" >&2
    exit 1
fi

printf 'Verified %s\n' "$BUNDLE_DIR"
