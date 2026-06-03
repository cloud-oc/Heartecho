#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION_VALUE="${VERSION:-}"
CONFIGURATION="release"
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
OUTPUT_DIR="$ROOT_DIR/build/pkg"
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
SIGN_RELEASE=0
NOTARIZE_RELEASE=0
REQUIRE_NOTARIZED=0
DEVELOPER_ID_APPLICATION_IDENTITY="${DEVELOPER_ID_APPLICATION_IDENTITY:-}"
DEVELOPER_ID_INSTALLER_IDENTITY="${DEVELOPER_ID_INSTALLER_IDENTITY:-}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-}"
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:-}"

if [ -z "$VERSION_VALUE" ]; then
    if [ -f "$ROOT_DIR/VERSION" ]; then
        VERSION_VALUE="$(sed -n '1p' "$ROOT_DIR/VERSION" | tr -d '[:space:]')"
    else
        VERSION_VALUE="0.1.0"
    fi
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --version\n' >&2; exit 64; }
            VERSION_VALUE="$1"
            ;;
        --configuration)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --configuration\n' >&2; exit 64; }
            CONFIGURATION="$1"
            ;;
        --build-number)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --build-number\n' >&2; exit 64; }
            BUILD_NUMBER="$1"
            ;;
        --sign)
            SIGN_RELEASE=1
            ;;
        --notarize)
            SIGN_RELEASE=1
            NOTARIZE_RELEASE=1
            ;;
        --require-notarized)
            SIGN_RELEASE=1
            NOTARIZE_RELEASE=1
            REQUIRE_NOTARIZED=1
            ;;
        --developer-id-application)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --developer-id-application\n' >&2; exit 64; }
            DEVELOPER_ID_APPLICATION_IDENTITY="$1"
            ;;
        --developer-id-installer)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --developer-id-installer\n' >&2; exit 64; }
            DEVELOPER_ID_INSTALLER_IDENTITY="$1"
            ;;
        --notary-keychain-profile)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --notary-keychain-profile\n' >&2; exit 64; }
            NOTARY_KEYCHAIN_PROFILE="$1"
            ;;
        --notary-apple-id)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --notary-apple-id\n' >&2; exit 64; }
            NOTARY_APPLE_ID="$1"
            ;;
        --notary-team-id)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --notary-team-id\n' >&2; exit 64; }
            NOTARY_TEAM_ID="$1"
            ;;
        --notary-password)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --notary-password\n' >&2; exit 64; }
            NOTARY_PASSWORD="$1"
            ;;
        --help|-h)
            printf 'Usage: %s [--version VERSION] [--configuration release|debug] [--build-number N] [--sign|--notarize|--require-notarized] [--developer-id-application NAME] [--developer-id-installer NAME] [--notary-keychain-profile NAME | --notary-apple-id EMAIL --notary-team-id TEAM --notary-password APP-PASSWORD]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

case "$CONFIGURATION" in
    debug|release) ;;
    *) printf 'Configuration must be debug or release: %s\n' "$CONFIGURATION" >&2; exit 64 ;;
esac

[ -n "$VERSION_VALUE" ] || { printf 'Version must not be empty.\n' >&2; exit 64; }

INSTALLER_PKG="$OUTPUT_DIR/Heartecho-$VERSION_VALUE.pkg"
UNINSTALLER_PKG="$OUTPUT_DIR/Heartecho-Uninstaller-$VERSION_VALUE.pkg"
PRODUCT_PKG="$OUTPUT_DIR/Heartecho-Distribution-$VERSION_VALUE.pkg"
DMG_PATH="$OUTPUT_DIR/Heartecho-$VERSION_VALUE.dmg"
MANIFEST_PATH="$ROOT_DIR/build/release-manifest.json"

mkdir -p "$OUTPUT_DIR" "$CLANG_MODULE_CACHE_PATH"

printf 'Heartecho release artifact build\n'
printf '%s\n' "- version: $VERSION_VALUE"
printf '%s\n' "- configuration: $CONFIGURATION"
printf '%s\n' "- build number: $BUILD_NUMBER"
printf '%s\n' "- output: $OUTPUT_DIR"
printf '%s\n' "- sign: $([ "$SIGN_RELEASE" -eq 1 ] && printf yes || printf no)"
printf '%s\n' "- notarize: $([ "$NOTARIZE_RELEASE" -eq 1 ] && printf yes || printf no)"

"$ROOT_DIR/scripts/check-swift-toolchain.sh"

if [ "$NOTARIZE_RELEASE" -eq 1 ]; then
    if [ -z "$NOTARY_KEYCHAIN_PROFILE" ] && { [ -z "$NOTARY_APPLE_ID" ] || [ -z "$NOTARY_TEAM_ID" ] || [ -z "$NOTARY_PASSWORD" ]; }; then
        printf 'Notarization requires NOTARY_KEYCHAIN_PROFILE or NOTARY_APPLE_ID, NOTARY_TEAM_ID, and NOTARY_PASSWORD.\n' >&2
        exit 64
    fi
fi

if [ "$SIGN_RELEASE" -eq 1 ]; then
    [ -n "$DEVELOPER_ID_APPLICATION_IDENTITY" ] || { printf 'Signing requires DEVELOPER_ID_APPLICATION_IDENTITY.\n' >&2; exit 64; }
    [ -n "$DEVELOPER_ID_INSTALLER_IDENTITY" ] || { printf 'Signing requires DEVELOPER_ID_INSTALLER_IDENTITY.\n' >&2; exit 64; }
fi

notarize_product_pkg() {
    if [ -n "$NOTARY_KEYCHAIN_PROFILE" ]; then
        "$ROOT_DIR/scripts/notarize-product-pkg.sh" \
            --package "$PRODUCT_PKG" \
            --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
            --staple \
            --execute
    else
        "$ROOT_DIR/scripts/notarize-product-pkg.sh" \
            --package "$PRODUCT_PKG" \
            --apple-id "$NOTARY_APPLE_ID" \
            --team-id "$NOTARY_TEAM_ID" \
            --password "$NOTARY_PASSWORD" \
            --staple \
            --execute
    fi
}

notarize_dmg() {
    if [ -n "$NOTARY_KEYCHAIN_PROFILE" ]; then
        "$ROOT_DIR/scripts/notarize-release-dmg.sh" \
            --dmg "$DMG_PATH" \
            --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
            --staple \
            --execute
    else
        "$ROOT_DIR/scripts/notarize-release-dmg.sh" \
            --dmg "$DMG_PATH" \
            --apple-id "$NOTARY_APPLE_ID" \
            --team-id "$NOTARY_TEAM_ID" \
            --password "$NOTARY_PASSWORD" \
            --staple \
            --execute
    fi
}

env CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" swift build -c "$CONFIGURATION" --disable-sandbox

"$ROOT_DIR/scripts/build-icons.sh"
"$ROOT_DIR/scripts/build-app-bundle.sh" "$CONFIGURATION" --version "$VERSION_VALUE" --build-number "$BUILD_NUMBER"
"$ROOT_DIR/scripts/verify-app-bundle.sh"
"$ROOT_DIR/scripts/build-hal-bundle.sh" "$CONFIGURATION"
"$ROOT_DIR/scripts/verify-hal-bundle.sh"

if [ "$SIGN_RELEASE" -eq 1 ]; then
    "$ROOT_DIR/scripts/sign-app-bundle.sh" \
        --app "$ROOT_DIR/build/App/Heartecho.app" \
        --identity "$DEVELOPER_ID_APPLICATION_IDENTITY" \
        --force \
        --execute
    "$ROOT_DIR/scripts/sign-hal-bundle.sh" \
        --bundle "$ROOT_DIR/build/HAL/Heartecho.driver" \
        --identity "$DEVELOPER_ID_APPLICATION_IDENTITY" \
        --force \
        --execute
    "$ROOT_DIR/scripts/sign-helper.sh" \
        --helper "$ROOT_DIR/.build/$CONFIGURATION/HeartechoHelper" \
        --identity "$DEVELOPER_ID_APPLICATION_IDENTITY" \
        --force \
        --execute
fi

"$ROOT_DIR/scripts/build-helper-launch-agent.sh" \
    --helper "$ROOT_DIR/.build/$CONFIGURATION/HeartechoHelper"

if [ -n "$DEVELOPER_ID_INSTALLER_IDENTITY" ]; then
    "$ROOT_DIR/scripts/build-installer-pkg.sh" \
        --execute \
        --configuration "$CONFIGURATION" \
        --version "$VERSION_VALUE" \
        --output "$INSTALLER_PKG" \
        --sign-pkg-identity "$DEVELOPER_ID_INSTALLER_IDENTITY"
else
    "$ROOT_DIR/scripts/build-installer-pkg.sh" \
        --execute \
        --configuration "$CONFIGURATION" \
        --version "$VERSION_VALUE" \
        --output "$INSTALLER_PKG"
fi
"$ROOT_DIR/scripts/verify-installer-pkg.sh" "$INSTALLER_PKG"

if [ -n "$DEVELOPER_ID_INSTALLER_IDENTITY" ]; then
    "$ROOT_DIR/scripts/build-uninstaller-pkg.sh" \
        --execute \
        --version "$VERSION_VALUE" \
        --output "$UNINSTALLER_PKG" \
        --sign-pkg-identity "$DEVELOPER_ID_INSTALLER_IDENTITY"
else
    "$ROOT_DIR/scripts/build-uninstaller-pkg.sh" \
        --execute \
        --version "$VERSION_VALUE" \
        --output "$UNINSTALLER_PKG"
fi
"$ROOT_DIR/scripts/verify-uninstaller-pkg.sh" "$UNINSTALLER_PKG"

if [ -n "$DEVELOPER_ID_INSTALLER_IDENTITY" ]; then
    "$ROOT_DIR/scripts/build-distribution-product.sh" \
        --execute \
        --version "$VERSION_VALUE" \
        --installer-pkg "$INSTALLER_PKG" \
        --uninstaller-pkg "$UNINSTALLER_PKG" \
        --output "$PRODUCT_PKG" \
        --sign-pkg-identity "$DEVELOPER_ID_INSTALLER_IDENTITY"
else
    "$ROOT_DIR/scripts/build-distribution-product.sh" \
        --execute \
        --version "$VERSION_VALUE" \
        --installer-pkg "$INSTALLER_PKG" \
        --uninstaller-pkg "$UNINSTALLER_PKG" \
        --output "$PRODUCT_PKG"
fi
"$ROOT_DIR/scripts/verify-distribution-product.sh" "$PRODUCT_PKG"

if [ "$SIGN_RELEASE" -eq 1 ]; then
    "$ROOT_DIR/scripts/check-product-signing.sh" \
        --require-valid \
        --version "$VERSION_VALUE" \
        --helper "$ROOT_DIR/.build/$CONFIGURATION/HeartechoHelper"
fi

if [ "$NOTARIZE_RELEASE" -eq 1 ]; then
    notarize_product_pkg
fi

"$ROOT_DIR/scripts/build-release-dmg.sh" \
    --version "$VERSION_VALUE" \
    --package "$PRODUCT_PKG" \
    --output "$DMG_PATH"
"$ROOT_DIR/scripts/verify-release-dmg.sh" "$DMG_PATH"

if [ "$NOTARIZE_RELEASE" -eq 1 ]; then
    notarize_dmg
    "$ROOT_DIR/scripts/verify-release-dmg.sh" "$DMG_PATH"
fi

if [ "$REQUIRE_NOTARIZED" -eq 1 ]; then
    "$ROOT_DIR/scripts/write-release-manifest.sh" \
        --configuration "$CONFIGURATION" \
        --version "$VERSION_VALUE" \
        --output "$MANIFEST_PATH" \
        --require-signed
else
    "$ROOT_DIR/scripts/write-release-manifest.sh" \
        --configuration "$CONFIGURATION" \
        --version "$VERSION_VALUE" \
        --output "$MANIFEST_PATH"
fi

printf 'Release artifacts ready\n'
printf '%s\n' "- installer: $INSTALLER_PKG"
printf '%s\n' "- uninstaller: $UNINSTALLER_PKG"
printf '%s\n' "- product: $PRODUCT_PKG"
printf '%s\n' "- dmg: $DMG_PATH"
printf '%s\n' "- manifest: $MANIFEST_PATH"
