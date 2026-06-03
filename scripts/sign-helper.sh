#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER_PATH="$ROOT_DIR/.build/debug/HeartechoHelper"
IDENTITY=""
EXECUTE=0
FORCE=0

while [ "$#" -gt 0 ]; do
    case "$1" in
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
        --force)
            FORCE=1
            ;;
        --execute)
            EXECUTE=1
            ;;
        --help|-h)
            printf 'Usage: %s --identity NAME [--helper PATH] [--force] [--execute]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

if [ -z "$IDENTITY" ]; then
    printf 'Missing required --identity NAME\n' >&2
    printf 'Use "Developer ID Application: ..." for distribution signing, or "-" for local ad-hoc development.\n' >&2
    exit 64
fi

[ -f "$HELPER_PATH" ] || { printf 'Missing helper executable: %s\n' "$HELPER_PATH" >&2; exit 1; }
[ -x "$HELPER_PATH" ] || { printf 'Helper is not executable: %s\n' "$HELPER_PATH" >&2; exit 1; }

FORCE_FLAG=""
if [ "$FORCE" -eq 1 ]; then
    FORCE_FLAG="--force"
fi

printf 'Helper signing plan\n'
printf '%s\n' "- helper: $HELPER_PATH"
printf '%s\n' "- identity: $IDENTITY"
printf '%s\n' "- force: $([ "$FORCE" -eq 1 ] && printf yes || printf no)"
printf '%s\n' "- mode: $([ "$EXECUTE" -eq 1 ] && printf execute || printf dry-run)"
printf '%s\n' "- command: codesign $FORCE_FLAG --timestamp --options runtime --sign \"$IDENTITY\" \"$HELPER_PATH\""

if [ "$EXECUTE" -ne 1 ]; then
    printf 'Dry run only. Re-run with --execute to sign the helper.\n'
    exit 0
fi

codesign $FORCE_FLAG --timestamp --options runtime --sign "$IDENTITY" "$HELPER_PATH"
codesign --verify --verbose "$HELPER_PATH"
