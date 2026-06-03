#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PACKAGE_FILE="${1:-$ROOT_DIR/Package.swift}"

[ -f "$PACKAGE_FILE" ] || {
    printf 'Missing Package.swift: %s\n' "$PACKAGE_FILE" >&2
    exit 1
}

REQUIRED_TOOLS_VERSION="$(sed -n 's|^// swift-tools-version:[[:space:]]*||p' "$PACKAGE_FILE" | sed -n '1p' | tr -d '[:space:]')"
[ -n "$REQUIRED_TOOLS_VERSION" ] || {
    printf 'Could not find a swift-tools-version declaration in %s\n' "$PACKAGE_FILE" >&2
    exit 1
}

if ! SWIFT_VERSION_OUTPUT="$(swift --version 2>&1)"; then
    printf 'Unable to run swift --version\n' >&2
    printf '%s\n' "$SWIFT_VERSION_OUTPUT" >&2
    exit 1
fi

SWIFT_VERSION_LINE="$(printf '%s\n' "$SWIFT_VERSION_OUTPUT" | sed -n '1p')"
INSTALLED_SWIFT_VERSION="$(
    printf '%s\n' "$SWIFT_VERSION_LINE" |
        awk '{
            for (i = 1; i <= NF; i++) {
                if ($i == "Swift" && $(i + 1) == "version") {
                    print $(i + 2)
                    exit
                }
            }
        }'
)"
INSTALLED_SWIFT_VERSION="$(printf '%s\n' "$INSTALLED_SWIFT_VERSION" | sed 's/[^0-9.].*$//')"

[ -n "$INSTALLED_SWIFT_VERSION" ] || {
    printf 'Could not parse installed Swift version from: %s\n' "$SWIFT_VERSION_LINE" >&2
    exit 1
}

version_part() {
    printf '%s\n' "$1" | awk -F. -v index="$2" '{ value = $index; if (value == "") value = 0; print value + 0 }'
}

REQUIRED_MAJOR="$(version_part "$REQUIRED_TOOLS_VERSION" 1)"
REQUIRED_MINOR="$(version_part "$REQUIRED_TOOLS_VERSION" 2)"
INSTALLED_MAJOR="$(version_part "$INSTALLED_SWIFT_VERSION" 1)"
INSTALLED_MINOR="$(version_part "$INSTALLED_SWIFT_VERSION" 2)"
DEVELOPER_DIR_PATH="$(xcode-select -p 2>/dev/null || printf 'unavailable')"

printf 'Swift toolchain check\n'
printf '%s\n' "- package tools version: $REQUIRED_TOOLS_VERSION"
printf '%s\n' "- installed Swift: $SWIFT_VERSION_LINE"
printf '%s\n' "- developer directory: $DEVELOPER_DIR_PATH"

if [ "$INSTALLED_MAJOR" -lt "$REQUIRED_MAJOR" ] ||
    { [ "$INSTALLED_MAJOR" -eq "$REQUIRED_MAJOR" ] && [ "$INSTALLED_MINOR" -lt "$REQUIRED_MINOR" ]; }; then
    printf 'error: Package.swift requires Swift tools %s or newer, but installed Swift is %s.\n' \
        "$REQUIRED_TOOLS_VERSION" "$INSTALLED_SWIFT_VERSION" >&2
    printf 'hint: Use Xcode 16 or newer for this package. On GitHub Actions, run on macos-15 and select /Applications/Xcode_16.4.app/Contents/Developer.\n' >&2
    exit 1
fi
