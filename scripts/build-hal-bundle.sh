#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"
OUTPUT_DIR="$ROOT_DIR/build/HAL"
BUNDLE_NAME="Heartecho.driver"
BUNDLE_DIR="$OUTPUT_DIR/$BUNDLE_NAME"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BINARY_PATH="$MACOS_DIR/HeartechoHALDriver"
DSYM_OUTPUT_DIR="$OUTPUT_DIR/dSYM"
INFO_PLIST_TEMPLATE="$ROOT_DIR/HALBundle/Heartecho.driver/Contents/Info.plist"
DRIVER_SOURCE="$ROOT_DIR/Sources/HALDriverC/HeartechoHALDriver.c"
INCLUDE_DIR="$ROOT_DIR/Sources/HALDriverC/include"
ICON_PATH="$ROOT_DIR/build/icons/HeartechoDriver.icns"
ICONSET_PATH="$ROOT_DIR/build/icons/HeartechoDriver.iconset"

case "$CONFIGURATION" in
    debug)
        OPT_FLAGS="-g -O0"
        ;;
    release)
        OPT_FLAGS="-O2"
        ;;
    *)
        printf '%s\n' "Usage: $0 [debug|release]" >&2
        exit 64
        ;;
esac

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
mkdir -p "$DSYM_OUTPUT_DIR"
rm -rf "$MACOS_DIR/HeartechoHALDriver.dSYM"
rm -f "$BINARY_PATH"
cp "$INFO_PLIST_TEMPLATE" "$CONTENTS_DIR/Info.plist"

if [ ! -f "$ICON_PATH" ] && [ ! -d "$ICONSET_PATH" ]; then
    "$ROOT_DIR/scripts/build-icons.sh" >/dev/null
fi
if [ -f "$ICON_PATH" ]; then
    rm -rf "$RESOURCES_DIR/HeartechoDriver.iconset"
    cp "$ICON_PATH" "$RESOURCES_DIR/HeartechoDriver.icns"
elif [ -d "$ICONSET_PATH" ]; then
    rm -f "$RESOURCES_DIR/HeartechoDriver.icns"
    rm -rf "$RESOURCES_DIR/HeartechoDriver.iconset"
    cp -R "$ICONSET_PATH" "$RESOURCES_DIR/HeartechoDriver.iconset"
else
    printf 'Missing HAL driver icon assets: %s or %s\n' "$ICON_PATH" "$ICONSET_PATH" >&2
    exit 1
fi

clang \
    -dynamiclib \
    $OPT_FLAGS \
    -isysroot "$SDK_PATH" \
    -mmacosx-version-min=14.0 \
    -fvisibility=hidden \
    -I "$INCLUDE_DIR" \
    "$DRIVER_SOURCE" \
    -framework CoreAudio \
    -framework CoreFoundation \
    -o "$BINARY_PATH"

chmod 755 "$BINARY_PATH"

if [ -d "$MACOS_DIR/HeartechoHALDriver.dSYM" ]; then
    rm -rf "$DSYM_OUTPUT_DIR/HeartechoHALDriver.dSYM"
    mv "$MACOS_DIR/HeartechoHALDriver.dSYM" "$DSYM_OUTPUT_DIR/HeartechoHALDriver.dSYM"
fi

printf 'Built %s\n' "$BUNDLE_DIR"
