#!/bin/sh
set -eu

BUNDLE_NAME="Heartecho.driver"
DEST_ROOT="$HOME/Library/Audio/Plug-Ins/HAL"
EXECUTE=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --destination)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --destination\n' >&2; exit 64; }
            DEST_ROOT="$1"
            ;;
        --system)
            DEST_ROOT="/Library/Audio/Plug-Ins/HAL"
            ;;
        --user)
            DEST_ROOT="$HOME/Library/Audio/Plug-Ins/HAL"
            ;;
        --execute)
            EXECUTE=1
            ;;
        --help|-h)
            printf 'Usage: %s [--user|--system|--destination PATH] [--execute]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

DEST_BUNDLE="$DEST_ROOT/$BUNDLE_NAME"

printf 'HAL uninstall plan\n'
printf '%s\n' "- target: $DEST_BUNDLE"
printf '%s\n' "- exists: $([ -d "$DEST_BUNDLE" ] && printf yes || printf no)"
printf '%s\n' "- mode: $([ "$EXECUTE" -eq 1 ] && printf execute || printf dry-run)"

if [ "$EXECUTE" -ne 1 ]; then
    printf 'Dry run only. Re-run with --execute to remove the bundle.\n'
    exit 0
fi

rm -rf "$DEST_BUNDLE"
printf 'Removed %s\n' "$DEST_BUNDLE"
printf 'Core Audio may need to reload before stale devices disappear.\n'
