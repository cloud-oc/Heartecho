#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUNDLE_DIR="$ROOT_DIR/build/HAL/Heartecho.driver"
OUTPUT_DIR="$ROOT_DIR/build/notarization"
ARCHIVE_PATH=""
KEYCHAIN_PROFILE=""
APPLE_ID=""
TEAM_ID=""
PASSWORD=""
EXECUTE=0
WAIT=1
STAPLE=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --bundle)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --bundle\n' >&2; exit 64; }
            BUNDLE_DIR="$1"
            ;;
        --output-dir)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --output-dir\n' >&2; exit 64; }
            OUTPUT_DIR="$1"
            ;;
        --archive)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --archive\n' >&2; exit 64; }
            ARCHIVE_PATH="$1"
            ;;
        --keychain-profile)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --keychain-profile\n' >&2; exit 64; }
            KEYCHAIN_PROFILE="$1"
            ;;
        --apple-id)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --apple-id\n' >&2; exit 64; }
            APPLE_ID="$1"
            ;;
        --team-id)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --team-id\n' >&2; exit 64; }
            TEAM_ID="$1"
            ;;
        --password)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --password\n' >&2; exit 64; }
            PASSWORD="$1"
            ;;
        --no-wait)
            WAIT=0
            ;;
        --staple)
            STAPLE=1
            ;;
        --execute)
            EXECUTE=1
            ;;
        --help|-h)
            printf 'Usage: %s [--bundle PATH] [--output-dir PATH] [--archive PATH] [--keychain-profile NAME | --apple-id EMAIL --team-id TEAM --password APP-PASSWORD] [--no-wait] [--staple] [--execute]\n' "$0"
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
SIGNING_STATUS="valid"
if ! "$ROOT_DIR/scripts/check-hal-signing.sh" --require-valid "$BUNDLE_DIR" >/tmp/heartecho-notarize-signing.log 2>&1; then
    SIGNING_STATUS="missing or invalid"
fi

if [ -z "$ARCHIVE_PATH" ]; then
    mkdir -p "$OUTPUT_DIR"
    ARCHIVE_PATH="$OUTPUT_DIR/$(basename "$BUNDLE_DIR").zip"
fi

if [ -n "$KEYCHAIN_PROFILE" ]; then
    AUTH_ARGS="--keychain-profile \"$KEYCHAIN_PROFILE\""
elif [ -n "$APPLE_ID" ] && [ -n "$TEAM_ID" ] && [ -n "$PASSWORD" ]; then
    AUTH_ARGS="--apple-id \"$APPLE_ID\" --team-id \"$TEAM_ID\" --password \"********\""
else
    AUTH_ARGS="<missing credentials>"
fi

WAIT_FLAG=""
if [ "$WAIT" -eq 1 ]; then
    WAIT_FLAG="--wait"
fi

printf 'HAL notarization plan\n'
printf '%s\n' "- bundle: $BUNDLE_DIR"
printf '%s\n' "- archive: $ARCHIVE_PATH"
printf '%s\n' "- signing: $SIGNING_STATUS"
printf '%s\n' "- auth: $AUTH_ARGS"
printf '%s\n' "- wait: $([ "$WAIT" -eq 1 ] && printf yes || printf no)"
printf '%s\n' "- staple: $([ "$STAPLE" -eq 1 ] && printf yes || printf no)"
printf '%s\n' "- mode: $([ "$EXECUTE" -eq 1 ] && printf execute || printf dry-run)"

printf '%s\n' "- archive command: ditto -c -k --keepParent \"$BUNDLE_DIR\" \"$ARCHIVE_PATH\""
printf '%s' "- submit command: xcrun notarytool submit \"$ARCHIVE_PATH\" "
if [ -n "$KEYCHAIN_PROFILE" ]; then
    printf '%s ' "--keychain-profile \"$KEYCHAIN_PROFILE\""
elif [ -n "$APPLE_ID" ] && [ -n "$TEAM_ID" ] && [ -n "$PASSWORD" ]; then
    printf '%s ' "--apple-id \"$APPLE_ID\" --team-id \"$TEAM_ID\" --password ********"
else
    printf '%s ' "<credentials>"
fi
printf '%s\n' "$WAIT_FLAG"

if [ "$STAPLE" -eq 1 ]; then
    printf '%s\n' "- staple command: xcrun stapler staple \"$BUNDLE_DIR\""
fi

if [ "$EXECUTE" -ne 1 ]; then
    printf 'Dry run only. Re-run with --execute to archive and submit to Apple notary service.\n'
    exit 0
fi

if [ "$SIGNING_STATUS" != "valid" ]; then
    printf 'Cannot notarize until the bundle has a valid Developer ID signature.\n' >&2
    sed 's/^/  /' /tmp/heartecho-notarize-signing.log >&2
    exit 1
fi

if [ -z "$KEYCHAIN_PROFILE" ] && { [ -z "$APPLE_ID" ] || [ -z "$TEAM_ID" ] || [ -z "$PASSWORD" ]; }; then
    printf 'Missing notarization credentials. Use --keychain-profile or --apple-id/--team-id/--password.\n' >&2
    exit 64
fi

mkdir -p "$(dirname "$ARCHIVE_PATH")"
ditto -c -k --keepParent "$BUNDLE_DIR" "$ARCHIVE_PATH"

if [ -n "$KEYCHAIN_PROFILE" ]; then
    xcrun notarytool submit "$ARCHIVE_PATH" --keychain-profile "$KEYCHAIN_PROFILE" $WAIT_FLAG
else
    xcrun notarytool submit "$ARCHIVE_PATH" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$PASSWORD" $WAIT_FLAG
fi

if [ "$STAPLE" -eq 1 ]; then
    xcrun stapler staple "$BUNDLE_DIR"
fi
