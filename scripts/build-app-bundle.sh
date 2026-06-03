#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CONFIGURATION="debug"
APP_NAME="Heartecho"
BUNDLE_ID="com.heartecho.Heartecho"
VERSION="0.1.0"
BUILD_NUMBER="1"
MIN_SYSTEM_VERSION="14.0"
OUTPUT_DIR="$ROOT_DIR/build/App"
ICON_PATH="$ROOT_DIR/build/icons/Heartecho.icns"
ICONSET_PATH="$ROOT_DIR/build/icons/Heartecho.iconset"
BUILD_FIRST=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        debug|release)
            CONFIGURATION="$1"
            ;;
        --configuration)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --configuration\n' >&2; exit 64; }
            CONFIGURATION="$1"
            ;;
        --output)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --output\n' >&2; exit 64; }
            OUTPUT_DIR="$1"
            ;;
        --bundle-id)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --bundle-id\n' >&2; exit 64; }
            BUNDLE_ID="$1"
            ;;
        --version)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --version\n' >&2; exit 64; }
            VERSION="$1"
            ;;
        --build-number)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --build-number\n' >&2; exit 64; }
            BUILD_NUMBER="$1"
            ;;
        --build)
            BUILD_FIRST=1
            ;;
        --help|-h)
            printf 'Usage: %s [debug|release] [--build] [--output DIR] [--bundle-id ID] [--version VERSION] [--build-number N]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

case "$CONFIGURATION" in
    debug|release) ;;
    *) printf 'Configuration must be debug or release: %s\n' "$CONFIGURATION" >&2; exit 64 ;;
esac

if [ "$BUILD_FIRST" -eq 1 ]; then
    swift build -c "$CONFIGURATION"
fi

PRODUCT_DIR="$ROOT_DIR/.build/$CONFIGURATION"
EXECUTABLE="$PRODUCT_DIR/$APP_NAME"
[ -x "$EXECUTABLE" ] || { printf 'Missing built executable: %s\n' "$EXECUTABLE" >&2; exit 1; }

APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$EXECUTABLE" "$MACOS_DIR/$APP_NAME"

if [ ! -f "$ICON_PATH" ] && [ ! -d "$ICONSET_PATH" ]; then
    "$ROOT_DIR/scripts/build-icons.sh" >/dev/null
fi
if [ -f "$ICON_PATH" ]; then
    cp "$ICON_PATH" "$RESOURCES_DIR/Heartecho.icns"
elif [ -d "$ICONSET_PATH" ]; then
    cp -R "$ICONSET_PATH" "$RESOURCES_DIR/Heartecho.iconset"
else
    printf 'Missing app icon assets: %s or %s\n' "$ICON_PATH" "$ICONSET_PATH" >&2
    exit 1
fi

cat >"$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>Heartecho</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_SYSTEM_VERSION</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Heartecho captures selected hardware input devices when you add them as audio sources.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Heartecho captures audio from selected applications and system audio sources when you add them to a virtual device.</string>
</dict>
</plist>
EOF

plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null

printf 'Built %s\n' "$APP_DIR"
printf '%s\n' "- executable: $MACOS_DIR/$APP_NAME"
printf '%s\n' "- bundle id: $BUNDLE_ID"
printf '%s\n' "- configuration: $CONFIGURATION"
printf '%s\n' "- version: $VERSION ($BUILD_NUMBER)"
