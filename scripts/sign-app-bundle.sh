#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/build/App/Heartecho.app"
IDENTITY=""
EXECUTE=0
FORCE=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --app)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --app\n' >&2; exit 64; }
            APP_DIR="$1"
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
            printf 'Usage: %s --identity NAME [--app PATH] [--force] [--execute]\n' "$0"
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

"$ROOT_DIR/scripts/verify-app-bundle.sh" "$APP_DIR" >/dev/null

FORCE_FLAG=""
if [ "$FORCE" -eq 1 ]; then
    FORCE_FLAG="--force"
fi

printf 'App signing plan\n'
printf '%s\n' "- app: $APP_DIR"
printf '%s\n' "- identity: $IDENTITY"
printf '%s\n' "- force: $([ "$FORCE" -eq 1 ] && printf yes || printf no)"
printf '%s\n' "- mode: $([ "$EXECUTE" -eq 1 ] && printf execute || printf dry-run)"
printf '%s\n' "- command: codesign $FORCE_FLAG --timestamp --options runtime --sign \"$IDENTITY\" \"$APP_DIR\""

if [ "$EXECUTE" -ne 1 ]; then
    printf 'Dry run only. Re-run with --execute to sign the app bundle.\n'
    exit 0
fi

codesign $FORCE_FLAG --timestamp --options runtime --sign "$IDENTITY" "$APP_DIR"
codesign --verify --deep --strict --verbose "$APP_DIR"
