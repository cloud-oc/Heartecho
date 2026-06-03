#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/build/App/Heartecho.app"
HAL_BUNDLE="$ROOT_DIR/build/HAL/Heartecho.driver"
CONFIGURATION="debug"
HELPER_PATH=""
LABEL="com.heartecho.Heartecho.Helper"
VERSION="0.1.0"
IDENTIFIER="com.heartecho.Heartecho.pkg"
OUTPUT_DIR="$ROOT_DIR/build/pkg"
STAGING_DIR="$ROOT_DIR/build/pkg/staging"
PKG_SCRIPTS_DIR="$ROOT_DIR/build/pkg/scripts"
PACKAGE_PATH=""
EXECUTE=0
BUILD=0
IDENTITY=""
FORCE_SIGN=0
SIGN_PKG_IDENTITY=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --execute)
            EXECUTE=1
            ;;
        --build)
            BUILD=1
            ;;
        debug|release)
            CONFIGURATION="$1"
            ;;
        --configuration)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --configuration\n' >&2; exit 64; }
            CONFIGURATION="$1"
            ;;
        --helper)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --helper\n' >&2; exit 64; }
            HELPER_PATH="$1"
            ;;
        --identity)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --identity\n' >&2; exit 64; }
            IDENTITY="$1"
            ;;
        --force-sign)
            FORCE_SIGN=1
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
            printf 'Usage: %s [debug|release] [--configuration debug|release] [--execute] [--build] [--helper PATH] [--identity NAME] [--force-sign] [--sign-pkg-identity NAME] [--version VERSION] [--identifier ID] [--output PATH]\n' "$0"
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

if [ -z "$HELPER_PATH" ]; then
    HELPER_PATH="$ROOT_DIR/.build/$CONFIGURATION/HeartechoHelper"
fi

if [ -z "$PACKAGE_PATH" ]; then
    PACKAGE_PATH="$OUTPUT_DIR/Heartecho-$VERSION.pkg"
fi

FORCE_SIGN_FLAG=""
if [ "$FORCE_SIGN" -eq 1 ]; then
    FORCE_SIGN_FLAG="--force"
fi

if [ "$BUILD" -eq 1 ]; then
    swift build -c "$CONFIGURATION"
    "$ROOT_DIR/scripts/build-app-bundle.sh" "$CONFIGURATION"
    "$ROOT_DIR/scripts/build-hal-bundle.sh" "$CONFIGURATION"
fi

"$ROOT_DIR/scripts/verify-app-bundle.sh" "$APP_DIR" >/dev/null
"$ROOT_DIR/scripts/verify-hal-bundle.sh" "$HAL_BUNDLE" >/dev/null
[ -x "$HELPER_PATH" ] || { printf 'Missing helper executable: %s\n' "$HELPER_PATH" >&2; exit 1; }

if [ -n "$IDENTITY" ]; then
    "$ROOT_DIR/scripts/sign-app-bundle.sh" --identity "$IDENTITY" $FORCE_SIGN_FLAG
    "$ROOT_DIR/scripts/sign-hal-bundle.sh" --identity "$IDENTITY" $FORCE_SIGN_FLAG
    "$ROOT_DIR/scripts/sign-helper.sh" --identity "$IDENTITY" $FORCE_SIGN_FLAG
fi

printf 'Heartecho package workflow\n'
printf '%s\n' "- mode: $([ "$EXECUTE" -eq 1 ] && printf execute || printf dry-run)"
printf '%s\n' "- package: $PACKAGE_PATH"
printf '%s\n' "- identifier: $IDENTIFIER"
printf '%s\n' "- version: $VERSION"
printf '%s\n' "- configuration: $CONFIGURATION"
printf '%s\n' "- app: $APP_DIR -> /Applications/Heartecho.app"
printf '%s\n' "- HAL: $HAL_BUNDLE -> /Library/Audio/Plug-Ins/HAL/Heartecho.driver"
printf '%s\n' "- helper: $HELPER_PATH -> /Library/Application Support/Heartecho/HeartechoHelper"
printf '%s\n' "- LaunchAgent: $LABEL.plist -> /Library/LaunchAgents/$LABEL.plist"
printf '%s\n' "- package signing identity: $([ -n "$SIGN_PKG_IDENTITY" ] && printf '%s' "$SIGN_PKG_IDENTITY" || printf none)"

if [ "$EXECUTE" -ne 1 ]; then
    printf 'Dry run only. Re-run with --execute to stage payload and build the pkg.\n'
    exit 0
fi

rm -rf "$STAGING_DIR"
rm -rf "$PKG_SCRIPTS_DIR"
mkdir -p \
    "$STAGING_DIR/Applications" \
    "$STAGING_DIR/Library/Audio/Plug-Ins/HAL" \
    "$STAGING_DIR/Library/Application Support/Heartecho" \
    "$STAGING_DIR/Library/LaunchAgents" \
    "$PKG_SCRIPTS_DIR" \
    "$OUTPUT_DIR"

ditto --norsrc --noextattr --noqtn --noacl "$APP_DIR" "$STAGING_DIR/Applications/Heartecho.app"
ditto --norsrc --noextattr --noqtn --noacl "$HAL_BUNDLE" "$STAGING_DIR/Library/Audio/Plug-Ins/HAL/Heartecho.driver"
ditto --norsrc --noextattr --noqtn --noacl "$HELPER_PATH" "$STAGING_DIR/Library/Application Support/Heartecho/HeartechoHelper"

"$ROOT_DIR/scripts/build-helper-launch-agent.sh" \
    --helper "/Library/Application Support/Heartecho/HeartechoHelper" \
    --output "$STAGING_DIR/Library/LaunchAgents/$LABEL.plist" \
    >/dev/null

find "$STAGING_DIR" -name '._*' -delete

cat >"$PKG_SCRIPTS_DIR/preinstall" <<'EOF'
#!/bin/sh
set -eu

LABEL="com.heartecho.Heartecho.Helper"
USER_AGENT="/Library/LaunchAgents/$LABEL.plist"
HAL_BUNDLE="/Library/Audio/Plug-Ins/HAL/Heartecho.driver"
APP_BUNDLE="/Applications/Heartecho.app"
HELPER_DIR="/Library/Application Support/Heartecho"

if [ -f "$USER_AGENT" ]; then
    launchctl bootout "gui/$(id -u)" "$USER_AGENT" 2>/dev/null || true
fi

rm -rf "$APP_BUNDLE"
rm -rf "$HAL_BUNDLE"
rm -rf "$HELPER_DIR"
rm -f "$USER_AGENT"

exit 0
EOF

cat >"$PKG_SCRIPTS_DIR/postinstall" <<'EOF'
#!/bin/sh
set -eu

LABEL="com.heartecho.Heartecho.Helper"
USER_AGENT="/Library/LaunchAgents/$LABEL.plist"
HELPER="/Library/Application Support/Heartecho/HeartechoHelper"

if [ -x "$HELPER" ]; then
    chmod 755 "$HELPER"
fi

if [ -f "$USER_AGENT" ]; then
    chmod 644 "$USER_AGENT"
    launchctl bootstrap "gui/$(id -u)" "$USER_AGENT" 2>/dev/null || true
fi

killall coreaudiod 2>/dev/null || true

exit 0
EOF

cat >"$PKG_SCRIPTS_DIR/postuninstall" <<'EOF'
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

chmod 755 "$PKG_SCRIPTS_DIR/preinstall" "$PKG_SCRIPTS_DIR/postinstall" "$PKG_SCRIPTS_DIR/postuninstall"
xattr -cr "$STAGING_DIR" "$PKG_SCRIPTS_DIR" 2>/dev/null || true

PKG_SIGN_ARGS=""
if [ -n "$SIGN_PKG_IDENTITY" ]; then
    PKG_SIGN_ARGS="--sign $SIGN_PKG_IDENTITY"
fi

# shellcheck disable=SC2086
COPYFILE_DISABLE=1 pkgbuild \
    --root "$STAGING_DIR" \
    --scripts "$PKG_SCRIPTS_DIR" \
    --filter '/\._' \
    --filter '\.DS_Store$' \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location "/" \
    $PKG_SIGN_ARGS \
    "$PACKAGE_PATH"

printf 'Built %s\n' "$PACKAGE_PATH"
