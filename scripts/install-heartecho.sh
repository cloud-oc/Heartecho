#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
EXECUTE=0
SYSTEM_INSTALL=0
ALLOW_UNSIGNED=0
IDENTITY=""
FORCE_SIGN=0
BUILD=0
LOAD_HELPER=0
RELOAD_CORE_AUDIO=0
WAIT_SECONDS=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --execute)
            EXECUTE=1
            ;;
        --system)
            SYSTEM_INSTALL=1
            ;;
        --user)
            SYSTEM_INSTALL=0
            ;;
        --allow-unsigned)
            ALLOW_UNSIGNED=1
            ;;
        --identity)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --identity\n' >&2; exit 64; }
            IDENTITY="$1"
            ;;
        --force-sign)
            FORCE_SIGN=1
            ;;
        --build)
            BUILD=1
            ;;
        --load-helper)
            LOAD_HELPER=1
            ;;
        --reload-core-audio)
            RELOAD_CORE_AUDIO=1
            ;;
        --wait)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --wait\n' >&2; exit 64; }
            WAIT_SECONDS="$1"
            ;;
        --help|-h)
            printf 'Usage: %s [--execute] [--user|--system] [--build] [--identity NAME] [--force-sign] [--allow-unsigned] [--load-helper] [--reload-core-audio] [--wait SECONDS]\n' "$0"
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

HAL_SCOPE_FLAG="--user"
if [ "$SYSTEM_INSTALL" -eq 1 ]; then
    HAL_SCOPE_FLAG="--system"
fi

EXECUTE_FLAG=""
if [ "$EXECUTE" -eq 1 ]; then
    EXECUTE_FLAG="--execute"
fi

ALLOW_UNSIGNED_FLAG=""
if [ "$ALLOW_UNSIGNED" -eq 1 ]; then
    ALLOW_UNSIGNED_FLAG="--allow-unsigned"
fi

FORCE_SIGN_FLAG=""
if [ "$FORCE_SIGN" -eq 1 ]; then
    FORCE_SIGN_FLAG="--force"
fi

LOAD_HELPER_FLAG=""
if [ "$LOAD_HELPER" -eq 1 ]; then
    LOAD_HELPER_FLAG="--load"
fi

printf 'Heartecho install workflow\n'
printf '%s\n' "- mode: $([ "$EXECUTE" -eq 1 ] && printf execute || printf dry-run)"
printf '%s\n' "- HAL scope: $([ "$SYSTEM_INSTALL" -eq 1 ] && printf system || printf user)"
printf '%s\n' "- build first: $([ "$BUILD" -eq 1 ] && printf yes || printf no)"
printf '%s\n' "- signing identity: $([ -n "$IDENTITY" ] && printf '%s' "$IDENTITY" || printf none)"
printf '%s\n' "- allow unsigned HAL install: $([ "$ALLOW_UNSIGNED" -eq 1 ] && printf yes || printf no)"
printf '%s\n' "- load helper: $([ "$LOAD_HELPER" -eq 1 ] && printf yes || printf no)"
printf '%s\n' "- reload Core Audio: $([ "$RELOAD_CORE_AUDIO" -eq 1 ] && printf yes || printf no)"
printf '%s\n' "- wait for device: ${WAIT_SECONDS}s"

if [ "$BUILD" -eq 1 ]; then
    swift build
    "$ROOT_DIR/scripts/build-app-bundle.sh" debug
    "$ROOT_DIR/scripts/build-hal-bundle.sh" debug
fi

"$ROOT_DIR/scripts/verify-app-bundle.sh"
"$ROOT_DIR/scripts/verify-hal-bundle.sh"
"$ROOT_DIR/scripts/build-helper-launch-agent.sh"

if [ -n "$IDENTITY" ]; then
    "$ROOT_DIR/scripts/sign-hal-bundle.sh" --identity "$IDENTITY" $FORCE_SIGN_FLAG $EXECUTE_FLAG
    "$ROOT_DIR/scripts/sign-helper.sh" --identity "$IDENTITY" $FORCE_SIGN_FLAG $EXECUTE_FLAG
else
    "$ROOT_DIR/scripts/check-hal-signing.sh" || true
fi

"$ROOT_DIR/scripts/install-hal-bundle.sh" $HAL_SCOPE_FLAG $ALLOW_UNSIGNED_FLAG $EXECUTE_FLAG
"$ROOT_DIR/scripts/install-helper-launch-agent.sh" $LOAD_HELPER_FLAG $EXECUTE_FLAG

if [ "$RELOAD_CORE_AUDIO" -eq 1 ]; then
    "$ROOT_DIR/scripts/reload-core-audio.sh" $EXECUTE_FLAG
fi

if [ "$WAIT_SECONDS" -gt 0 ]; then
    if [ "$EXECUTE" -eq 1 ]; then
        swift run HeartechoDiagnostics --wait-hal-device "$WAIT_SECONDS"
    else
        printf 'Dry run only. Would run: swift run HeartechoDiagnostics --wait-hal-device %s\n' "$WAIT_SECONDS"
    fi
fi

if [ "$EXECUTE" -eq 1 ]; then
    "$ROOT_DIR/scripts/validate-installation.sh" --strict --wait "$WAIT_SECONDS"
else
    printf 'Dry run only. Would run: scripts/validate-installation.sh --strict --wait %s\n' "$WAIT_SECONDS"
fi

printf 'Heartecho install workflow finished.\n'
