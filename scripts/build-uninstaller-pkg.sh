#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="0.1.0"
IDENTIFIER="com.heartecho.Heartecho.uninstaller.pkg"
OUTPUT_DIR="$ROOT_DIR/build/pkg"
PKG_SCRIPTS_DIR="$ROOT_DIR/build/pkg/uninstaller-scripts"
PACKAGE_PATH=""
EXECUTE=0
SIGN_PKG_IDENTITY=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --execute)
            EXECUTE=1
            ;;
        --sign-pkg-identity)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --sign-pkg-identity\n' >&2; exit 64; }
            SIGN_PKG_IDENTITY="$1"
            ;;
        --version)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --version\n' >&2; exit 64; }
            VERSION="$1"
            ;;
        --identifier)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --identifier\n' >&2; exit 64; }
            IDENTIFIER="$1"
            ;;
        --output)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --output\n' >&2; exit 64; }
            PACKAGE_PATH="$1"
            ;;
        --help|-h)
            printf 'Usage: %s [--execute] [--sign-pkg-identity NAME] [--version VERSION] [--identifier ID] [--output PATH]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

if [ -z "$PACKAGE_PATH" ]; then
    PACKAGE_PATH="$OUTPUT_DIR/Heartecho-Uninstaller-$VERSION.pkg"
fi

printf 'Heartecho uninstaller package workflow\n'
printf '%s\n' "- mode: $([ "$EXECUTE" -eq 1 ] && printf execute || printf dry-run)"
printf '%s\n' "- package: $PACKAGE_PATH"
printf '%s\n' "- identifier: $IDENTIFIER"
printf '%s\n' "- version: $VERSION"
printf '%s\n' "- removes: /Applications/Heartecho.app"
printf '%s\n' "- removes: /Library/Audio/Plug-Ins/HAL/Heartecho.driver"
printf '%s\n' "- removes: /Library/Application Support/Heartecho"
printf '%s\n' "- removes: /Library/LaunchAgents/com.heartecho.Heartecho.Helper.plist"
printf '%s\n' "- package signing identity: $([ -n "$SIGN_PKG_IDENTITY" ] && printf '%s' "$SIGN_PKG_IDENTITY" || printf none)"

if [ "$EXECUTE" -ne 1 ]; then
    printf 'Dry run only. Re-run with --execute to build the uninstaller pkg.\n'
    exit 0
fi

rm -rf "$PKG_SCRIPTS_DIR"
mkdir -p "$PKG_SCRIPTS_DIR" "$OUTPUT_DIR"

cat >"$PKG_SCRIPTS_DIR/preinstall" <<'EOF'
#!/bin/sh
set -eu

LABEL="com.heartecho.Heartecho.Helper"
USER_AGENT="/Library/LaunchAgents/$LABEL.plist"

if [ -f "$USER_AGENT" ]; then
    launchctl bootout "gui/$(id -u)" "$USER_AGENT" 2>/dev/null || true
fi

exit 0
EOF

cat >"$PKG_SCRIPTS_DIR/postinstall" <<'EOF'
#!/bin/sh
set -eu

LABEL="com.heartecho.Heartecho.Helper"
USER_AGENT="/Library/LaunchAgents/$LABEL.plist"

if [ -f "$USER_AGENT" ]; then
    launchctl bootout "gui/$(id -u)" "$USER_AGENT" 2>/dev/null || true
fi

rm -rf "/Applications/Heartecho.app"
rm -rf "/Library/Audio/Plug-Ins/HAL/Heartecho.driver"
rm -rf "/Library/Application Support/Heartecho"
rm -f "$USER_AGENT"

killall coreaudiod 2>/dev/null || true

exit 0
EOF

chmod 755 "$PKG_SCRIPTS_DIR/preinstall" "$PKG_SCRIPTS_DIR/postinstall"
xattr -cr "$PKG_SCRIPTS_DIR" 2>/dev/null || true

if [ -n "$SIGN_PKG_IDENTITY" ]; then
    COPYFILE_DISABLE=1 pkgbuild \
        --nopayload \
        --scripts "$PKG_SCRIPTS_DIR" \
        --identifier "$IDENTIFIER" \
        --version "$VERSION" \
        --sign "$SIGN_PKG_IDENTITY" \
        "$PACKAGE_PATH"
else
    COPYFILE_DISABLE=1 pkgbuild \
        --nopayload \
        --scripts "$PKG_SCRIPTS_DIR" \
        --identifier "$IDENTIFIER" \
        --version "$VERSION" \
        "$PACKAGE_PATH"
fi

printf 'Built %s\n' "$PACKAGE_PATH"
