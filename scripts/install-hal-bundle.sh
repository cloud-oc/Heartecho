#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUNDLE_DIR="$ROOT_DIR/build/HAL/Heartecho.driver"
DEST_ROOT="$HOME/Library/Audio/Plug-Ins/HAL"
EXECUTE=0
ALLOW_UNSIGNED=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --bundle)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --bundle\n' >&2; exit 64; }
            BUNDLE_DIR="$1"
            ;;
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
        --allow-unsigned)
            ALLOW_UNSIGNED=1
            ;;
        --help|-h)
            printf 'Usage: %s [--bundle PATH] [--user|--system|--destination PATH] [--allow-unsigned] [--execute]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

"$ROOT_DIR/scripts/verify-hal-bundle.sh" "$BUNDLE_DIR" >/dev/null

DEST_BUNDLE="$DEST_ROOT/$(basename "$BUNDLE_DIR")"

printf 'HAL install plan\n'
printf '%s\n' "- source: $BUNDLE_DIR"
printf '%s\n' "- destination: $DEST_BUNDLE"
printf '%s\n' "- signature gate: $([ "$ALLOW_UNSIGNED" -eq 1 ] && printf allow-unsigned || printf require-valid)"
printf '%s\n' "- mode: $([ "$EXECUTE" -eq 1 ] && printf execute || printf dry-run)"

if [ "$EXECUTE" -ne 1 ]; then
    printf 'Dry run only. Re-run with --execute to copy the bundle.\n'
    exit 0
fi

if [ "$ALLOW_UNSIGNED" -ne 1 ]; then
    "$ROOT_DIR/scripts/check-hal-signing.sh" --require-valid "$BUNDLE_DIR" >/dev/null
fi

mkdir -p "$DEST_ROOT"
rm -rf "$DEST_BUNDLE"
cp -R "$BUNDLE_DIR" "$DEST_BUNDLE"

printf 'Installed %s\n' "$DEST_BUNDLE"
printf 'Core Audio may need to reload the HAL plug-in before the device appears.\n'
