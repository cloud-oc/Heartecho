#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PLIST_PATH="$ROOT_DIR/build/launchd/com.heartecho.Heartecho.Helper.plist"
DEST_ROOT="$HOME/Library/LaunchAgents"
EXECUTE=0
LOAD=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --plist)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --plist\n' >&2; exit 64; }
            PLIST_PATH="$1"
            ;;
        --destination)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --destination\n' >&2; exit 64; }
            DEST_ROOT="$1"
            ;;
        --execute)
            EXECUTE=1
            ;;
        --load)
            LOAD=1
            ;;
        --help|-h)
            printf 'Usage: %s [--plist PATH] [--destination PATH] [--execute] [--load]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

[ -f "$PLIST_PATH" ] || { printf 'Missing helper LaunchAgent plist: %s\n' "$PLIST_PATH" >&2; exit 1; }
plutil -lint "$PLIST_PATH" >/dev/null

LABEL="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST_PATH")"
HELPER_PATH="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST_PATH")"
DEST_PATH="$DEST_ROOT/$LABEL.plist"

printf 'Helper LaunchAgent install plan\n'
printf '%s\n' "- source: $PLIST_PATH"
printf '%s\n' "- destination: $DEST_PATH"
printf '%s\n' "- helper: $HELPER_PATH"
printf '%s\n' "- helper executable: $([ -x "$HELPER_PATH" ] && printf yes || printf no)"
printf '%s\n' "- mode: $([ "$EXECUTE" -eq 1 ] && printf execute || printf dry-run)"
printf '%s\n' "- launchctl load: $([ "$LOAD" -eq 1 ] && printf requested || printf skipped)"

if [ "$EXECUTE" -ne 1 ]; then
    printf 'Dry run only. Re-run with --execute to copy the LaunchAgent plist.\n'
    exit 0
fi

[ -x "$HELPER_PATH" ] || { printf 'Helper is not executable: %s\n' "$HELPER_PATH" >&2; exit 1; }

mkdir -p "$DEST_ROOT"
cp "$PLIST_PATH" "$DEST_PATH"

printf 'Installed %s\n' "$DEST_PATH"

if [ "$LOAD" -eq 1 ]; then
    launchctl bootstrap "gui/$(id -u)" "$DEST_PATH"
    printf 'Loaded %s\n' "$LABEL"
else
    printf 'LaunchAgent not loaded. Use --load with --execute after signing/install validation.\n'
fi
