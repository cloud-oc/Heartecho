#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LABEL="com.heartecho.Heartecho.Helper"
APP_PATH="/Applications/Heartecho.app"
USER_HAL="$HOME/Library/Audio/Plug-Ins/HAL/Heartecho.driver"
SYSTEM_HAL="/Library/Audio/Plug-Ins/HAL/Heartecho.driver"
HELPER_PATH="/Library/Application Support/Heartecho/HeartechoHelper"
USER_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
SYSTEM_AGENT="/Library/LaunchAgents/$LABEL.plist"
WAIT_SECONDS=0
STRICT=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --wait)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --wait\n' >&2; exit 64; }
            WAIT_SECONDS="$1"
            ;;
        --strict)
            STRICT=1
            ;;
        --help|-h)
            printf 'Usage: %s [--wait SECONDS] [--strict]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

case "$WAIT_SECONDS" in
    ''|*[!0-9]*) printf 'Wait seconds must be a non-negative integer: %s\n' "$WAIT_SECONDS" >&2; exit 64 ;;
esac

FAILURES=0

check_file() {
    label="$1"
    path="$2"
    executable="${3:-no}"

    if [ "$executable" = "yes" ]; then
        ok=$([ -x "$path" ] && printf yes || printf no)
    else
        ok=$([ -e "$path" ] && printf yes || printf no)
    fi

    printf '%s\n' "- $label: $ok ($path)"
    if [ "$ok" != yes ]; then
        FAILURES=$((FAILURES + 1))
    fi
}

printf 'Heartecho installation validation\n'
check_file "App bundle" "$APP_PATH"

if [ -d "$SYSTEM_HAL" ]; then
    HAL_PATH="$SYSTEM_HAL"
elif [ -d "$USER_HAL" ]; then
    HAL_PATH="$USER_HAL"
else
    HAL_PATH="$SYSTEM_HAL"
fi

check_file "HAL driver" "$HAL_PATH"
if [ -d "$HAL_PATH" ]; then
    if "$ROOT_DIR/scripts/verify-hal-bundle.sh" "$HAL_PATH" >/dev/null 2>&1; then
        printf '%s\n' "- HAL structure: yes"
    else
        printf '%s\n' "- HAL structure: no"
        FAILURES=$((FAILURES + 1))
    fi

    if codesign --verify --strict "$HAL_PATH" >/dev/null 2>&1; then
        printf '%s\n' "- HAL signature: valid"
    else
        printf '%s\n' "- HAL signature: missing or invalid"
        FAILURES=$((FAILURES + 1))
    fi
fi

check_file "Helper executable" "$HELPER_PATH" yes

if [ -f "$SYSTEM_AGENT" ]; then
    AGENT_PATH="$SYSTEM_AGENT"
elif [ -f "$USER_AGENT" ]; then
    AGENT_PATH="$USER_AGENT"
else
    AGENT_PATH="$SYSTEM_AGENT"
fi

check_file "Helper LaunchAgent" "$AGENT_PATH"
if [ -f "$AGENT_PATH" ]; then
    if plutil -lint "$AGENT_PATH" >/dev/null 2>&1; then
        printf '%s\n' "- Helper LaunchAgent plist: valid"
    else
        printf '%s\n' "- Helper LaunchAgent plist: invalid"
        FAILURES=$((FAILURES + 1))
    fi
fi

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    printf '%s\n' "- Helper launchd state: loaded"
else
    printf '%s\n' "- Helper launchd state: not loaded"
    FAILURES=$((FAILURES + 1))
fi

if [ "$WAIT_SECONDS" -gt 0 ]; then
    RESULT="$(.build/debug/HeartechoDiagnostics --wait-hal-device "$WAIT_SECONDS" 2>/dev/null | sed -n 's/^- HAL visibility wait: //p' | tail -1)"
    if [ -z "$RESULT" ]; then
        RESULT="$(swift run HeartechoDiagnostics --wait-hal-device "$WAIT_SECONDS" 2>/dev/null | sed -n 's/^- HAL visibility wait: //p' | tail -1)"
    fi
    printf '%s\n' "- HAL visibility wait: ${RESULT:-unknown}"
    case "$RESULT" in
        visible*) ;;
        *) FAILURES=$((FAILURES + 1)) ;;
    esac
else
    printf '%s\n' "- HAL visibility wait: skipped"
fi

printf '%s\n' "- failures: $FAILURES"

if [ "$STRICT" -eq 1 ] && [ "$FAILURES" -gt 0 ]; then
    exit 1
fi

exit 0
