#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUNDLE_DIR="${1:-$ROOT_DIR/build/HAL/Heartecho.driver}"
BINARY_PATH="$BUNDLE_DIR/Contents/MacOS/HeartechoHALDriver"
REQUIRE_VALID=0

if [ "${1:-}" = "--require-valid" ]; then
    REQUIRE_VALID=1
    BUNDLE_DIR="${2:-$ROOT_DIR/build/HAL/Heartecho.driver}"
    BINARY_PATH="$BUNDLE_DIR/Contents/MacOS/HeartechoHALDriver"
fi

"$ROOT_DIR/scripts/verify-hal-bundle.sh" "$BUNDLE_DIR" >/dev/null

printf 'HAL bundle: %s\n' "$BUNDLE_DIR"

SIGNATURE_VALID=0
if codesign --verify --strict --verbose=2 "$BUNDLE_DIR" >/tmp/heartecho-codesign-verify.log 2>&1; then
    SIGNATURE_VALID=1
    printf 'Code signature: valid\n'
else
    printf 'Code signature: missing or invalid\n'
    sed 's/^/  /' /tmp/heartecho-codesign-verify.log
fi

printf 'Bundle signing info:\n'
if codesign -dv "$BUNDLE_DIR" >/tmp/heartecho-codesign-info.log 2>&1; then
    sed 's/^/  /' /tmp/heartecho-codesign-info.log
else
    sed 's/^/  /' /tmp/heartecho-codesign-info.log
fi

printf 'Binary signing info:\n'
if codesign -dv "$BINARY_PATH" >/tmp/heartecho-codesign-binary.log 2>&1; then
    sed 's/^/  /' /tmp/heartecho-codesign-binary.log
else
    sed 's/^/  /' /tmp/heartecho-codesign-binary.log
fi

printf 'Notarization: not checked by this script; use notarytool after signing for distribution.\n'

if [ "$REQUIRE_VALID" -eq 1 ] && [ "$SIGNATURE_VALID" -ne 1 ]; then
    exit 1
fi
