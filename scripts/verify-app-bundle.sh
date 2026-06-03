#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_DIR="${1:-$ROOT_DIR/build/App/Heartecho.app}"
INFO_PLIST="$APP_DIR/Contents/Info.plist"

[ -d "$APP_DIR" ] || { printf 'Missing app bundle: %s\n' "$APP_DIR" >&2; exit 1; }
[ -f "$INFO_PLIST" ] || { printf 'Missing Info.plist: %s\n' "$INFO_PLIST" >&2; exit 1; }
plutil -lint "$INFO_PLIST" >/dev/null

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
PACKAGE_TYPE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$INFO_PLIST")"
ICON_FILE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$INFO_PLIST" 2>/dev/null || true)"
MIN_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")"
MICROPHONE_USAGE_DESCRIPTION="$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$INFO_PLIST" 2>/dev/null || true)"
AUDIO_CAPTURE_USAGE_DESCRIPTION="$(/usr/libexec/PlistBuddy -c 'Print :NSAudioCaptureUsageDescription' "$INFO_PLIST" 2>/dev/null || true)"

if [ "$EXECUTABLE_NAME" != "Heartecho" ]; then
    printf 'Unexpected CFBundleExecutable: %s\n' "$EXECUTABLE_NAME" >&2
    exit 1
fi

if [ "$BUNDLE_ID" != "com.heartecho.Heartecho" ]; then
    printf 'Unexpected CFBundleIdentifier: %s\n' "$BUNDLE_ID" >&2
    exit 1
fi

if [ "$PACKAGE_TYPE" != "APPL" ]; then
    printf 'Unexpected CFBundlePackageType: %s\n' "$PACKAGE_TYPE" >&2
    exit 1
fi

if [ "$ICON_FILE" != "Heartecho" ]; then
    printf 'Unexpected or missing CFBundleIconFile: %s\n' "$ICON_FILE" >&2
    exit 1
fi

if [ ! -f "$APP_DIR/Contents/Resources/Heartecho.icns" ]; then
    ICONSET_DIR="$APP_DIR/Contents/Resources/Heartecho.iconset"
    [ -d "$ICONSET_DIR" ] || { printf 'Missing app icon resource.\n' >&2; exit 1; }
    [ ! -d "$ICONSET_DIR/Heartecho.iconset" ] || {
        printf 'Unexpected nested app iconset directory.\n' >&2
        exit 1
    }
    for icon_name in icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png icon_128x128.png icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png icon_512x512.png icon_512x512@2x.png; do
        [ -f "$ICONSET_DIR/$icon_name" ] || {
            printf 'Missing app iconset image: %s\n' "$icon_name" >&2
            exit 1
        }
    done
fi

if [ "$MIN_SYSTEM_VERSION" != "14.0" ]; then
    printf 'Unexpected LSMinimumSystemVersion: %s\n' "$MIN_SYSTEM_VERSION" >&2
    exit 1
fi

if [ -z "$MICROPHONE_USAGE_DESCRIPTION" ]; then
    printf 'Missing NSMicrophoneUsageDescription in Info.plist.\n' >&2
    exit 1
fi

if [ -z "$AUDIO_CAPTURE_USAGE_DESCRIPTION" ]; then
    printf 'Missing NSAudioCaptureUsageDescription in Info.plist.\n' >&2
    exit 1
fi

EXECUTABLE_PATH="$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
[ -x "$EXECUTABLE_PATH" ] || { printf 'Missing executable binary: %s\n' "$EXECUTABLE_PATH" >&2; exit 1; }

FILE_OUTPUT="$(file "$EXECUTABLE_PATH")"
case "$FILE_OUTPUT" in
    *Mach-O*executable*) ;;
    *) printf 'Executable is not a Mach-O executable: %s\n' "$FILE_OUTPUT" >&2; exit 1 ;;
esac

printf 'Verified %s\n' "$APP_DIR"
