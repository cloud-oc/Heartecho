#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
EXECUTE=0
SYSTEM_INSTALL=0
UNLOAD_HELPER=0
RELOAD_CORE_AUDIO=0

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
        --unload-helper)
            UNLOAD_HELPER=1
            ;;
        --reload-core-audio)
            RELOAD_CORE_AUDIO=1
            ;;
        --help|-h)
            printf 'Usage: %s [--execute] [--user|--system] [--unload-helper] [--reload-core-audio]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

HAL_SCOPE_FLAG="--user"
if [ "$SYSTEM_INSTALL" -eq 1 ]; then
    HAL_SCOPE_FLAG="--system"
fi

EXECUTE_FLAG=""
if [ "$EXECUTE" -eq 1 ]; then
    EXECUTE_FLAG="--execute"
fi

UNLOAD_HELPER_FLAG=""
if [ "$UNLOAD_HELPER" -eq 1 ]; then
    UNLOAD_HELPER_FLAG="--unload"
fi

printf 'Heartecho uninstall workflow\n'
printf '%s\n' "- mode: $([ "$EXECUTE" -eq 1 ] && printf execute || printf dry-run)"
printf '%s\n' "- HAL scope: $([ "$SYSTEM_INSTALL" -eq 1 ] && printf system || printf user)"
printf '%s\n' "- unload helper: $([ "$UNLOAD_HELPER" -eq 1 ] && printf yes || printf no)"
printf '%s\n' "- reload Core Audio: $([ "$RELOAD_CORE_AUDIO" -eq 1 ] && printf yes || printf no)"

"$ROOT_DIR/scripts/uninstall-helper-launch-agent.sh" $UNLOAD_HELPER_FLAG $EXECUTE_FLAG
"$ROOT_DIR/scripts/uninstall-hal-bundle.sh" $HAL_SCOPE_FLAG $EXECUTE_FLAG

if [ "$RELOAD_CORE_AUDIO" -eq 1 ]; then
    "$ROOT_DIR/scripts/reload-core-audio.sh" $EXECUTE_FLAG
fi

printf 'Heartecho uninstall workflow finished.\n'
