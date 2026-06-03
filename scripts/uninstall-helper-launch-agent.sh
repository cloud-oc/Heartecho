#!/bin/sh
set -eu

LABEL="com.heartecho.Heartecho.Helper"
DEST_ROOT="$HOME/Library/LaunchAgents"
EXECUTE=0
UNLOAD=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --label)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --label\n' >&2; exit 64; }
            LABEL="$1"
            ;;
        --destination)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --destination\n' >&2; exit 64; }
            DEST_ROOT="$1"
            ;;
        --execute)
            EXECUTE=1
            ;;
        --unload)
            UNLOAD=1
            ;;
        --help|-h)
            printf 'Usage: %s [--label LABEL] [--destination PATH] [--execute] [--unload]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

DEST_PATH="$DEST_ROOT/$LABEL.plist"

printf 'Helper LaunchAgent uninstall plan\n'
printf '%s\n' "- label: $LABEL"
printf '%s\n' "- plist: $DEST_PATH"
printf '%s\n' "- exists: $([ -f "$DEST_PATH" ] && printf yes || printf no)"
printf '%s\n' "- mode: $([ "$EXECUTE" -eq 1 ] && printf execute || printf dry-run)"
printf '%s\n' "- launchctl unload: $([ "$UNLOAD" -eq 1 ] && printf requested || printf skipped)"

if [ "$EXECUTE" -ne 1 ]; then
    printf 'Dry run only. Re-run with --execute to remove the LaunchAgent plist.\n'
    exit 0
fi

if [ "$UNLOAD" -eq 1 ] && [ -f "$DEST_PATH" ]; then
    launchctl bootout "gui/$(id -u)" "$DEST_PATH" 2>/dev/null || true
    printf 'Requested unload for %s\n' "$LABEL"
fi

if [ -f "$DEST_PATH" ]; then
    rm -f "$DEST_PATH"
    printf 'Removed %s\n' "$DEST_PATH"
else
    printf 'No LaunchAgent plist found at %s\n' "$DEST_PATH"
fi
