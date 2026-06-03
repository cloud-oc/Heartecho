#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PACKAGE_PATH="$ROOT_DIR/build/pkg/Heartecho-Distribution-0.1.0.pkg"
KEYCHAIN_PROFILE=""
APPLE_ID=""
TEAM_ID=""
PASSWORD=""
EXECUTE=0
WAIT=1
STAPLE=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --package)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --package\n' >&2; exit 64; }
            PACKAGE_PATH="$1"
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
            printf 'Usage: %s [--package PATH] [--keychain-profile NAME | --apple-id EMAIL --team-id TEAM --password APP-PASSWORD] [--no-wait] [--staple] [--execute]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

SIGNING_STATUS="valid"
if [ ! -f "$PACKAGE_PATH" ]; then
    SIGNING_STATUS="missing package"
    printf 'Package not found: %s\n' "$PACKAGE_PATH" >/tmp/heartecho-product-signing.log
elif ! pkgutil --check-signature "$PACKAGE_PATH" >/tmp/heartecho-product-signing.log 2>&1; then
    SIGNING_STATUS="missing or invalid"
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

printf 'Product package notarization plan\n'
printf '%s\n' "- package: $PACKAGE_PATH"
printf '%s\n' "- signing: $SIGNING_STATUS"
printf '%s\n' "- auth: $AUTH_ARGS"
printf '%s\n' "- wait: $([ "$WAIT" -eq 1 ] && printf yes || printf no)"
printf '%s\n' "- staple: $([ "$STAPLE" -eq 1 ] && printf yes || printf no)"
printf '%s\n' "- mode: $([ "$EXECUTE" -eq 1 ] && printf execute || printf dry-run)"
printf '%s' "- submit command: xcrun notarytool submit \"$PACKAGE_PATH\" "
if [ -n "$KEYCHAIN_PROFILE" ]; then
    printf '%s ' "--keychain-profile \"$KEYCHAIN_PROFILE\""
elif [ -n "$APPLE_ID" ] && [ -n "$TEAM_ID" ] && [ -n "$PASSWORD" ]; then
    printf '%s ' "--apple-id \"$APPLE_ID\" --team-id \"$TEAM_ID\" --password ********"
else
    printf '%s ' "<credentials>"
fi
printf '%s\n' "$WAIT_FLAG"

if [ "$STAPLE" -eq 1 ]; then
    printf '%s\n' "- staple command: xcrun stapler staple \"$PACKAGE_PATH\""
fi

if [ "$EXECUTE" -ne 1 ]; then
    printf 'Dry run only. Re-run with --execute to submit the signed product package to Apple notary service.\n'
    exit 0
fi

if [ ! -f "$PACKAGE_PATH" ]; then
    printf 'Missing product package: %s\n' "$PACKAGE_PATH" >&2
    exit 1
fi

if [ "$SIGNING_STATUS" != "valid" ]; then
    printf 'Cannot notarize until the product package has a valid Developer ID Installer signature.\n' >&2
    sed 's/^/  /' /tmp/heartecho-product-signing.log >&2
    exit 1
fi

if [ -z "$KEYCHAIN_PROFILE" ] && { [ -z "$APPLE_ID" ] || [ -z "$TEAM_ID" ] || [ -z "$PASSWORD" ]; }; then
    printf 'Missing notarization credentials. Use --keychain-profile or --apple-id/--team-id/--password.\n' >&2
    exit 64
fi

if [ -n "$KEYCHAIN_PROFILE" ]; then
    xcrun notarytool submit "$PACKAGE_PATH" --keychain-profile "$KEYCHAIN_PROFILE" $WAIT_FLAG
else
    xcrun notarytool submit "$PACKAGE_PATH" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$PASSWORD" $WAIT_FLAG
fi

if [ "$STAPLE" -eq 1 ]; then
    xcrun stapler staple "$PACKAGE_PATH"
fi
