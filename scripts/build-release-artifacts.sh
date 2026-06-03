#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION_VALUE="${VERSION:-}"
CONFIGURATION="release"
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
OUTPUT_DIR="$ROOT_DIR/build/pkg"
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"

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
        --help|-h)
            printf 'Usage: %s [--version VERSION] [--configuration release|debug] [--build-number N]\n' "$0"
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
MANIFEST_PATH="$ROOT_DIR/build/release-manifest.json"

mkdir -p "$OUTPUT_DIR" "$CLANG_MODULE_CACHE_PATH"

printf 'Heartecho release artifact build\n'
printf '%s\n' "- version: $VERSION_VALUE"
printf '%s\n' "- configuration: $CONFIGURATION"
printf '%s\n' "- build number: $BUILD_NUMBER"
printf '%s\n' "- output: $OUTPUT_DIR"

"$ROOT_DIR/scripts/check-swift-toolchain.sh"

env CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" swift build -c "$CONFIGURATION" --disable-sandbox

"$ROOT_DIR/scripts/build-icons.sh"
"$ROOT_DIR/scripts/build-app-bundle.sh" "$CONFIGURATION" --version "$VERSION_VALUE" --build-number "$BUILD_NUMBER"
"$ROOT_DIR/scripts/verify-app-bundle.sh"
"$ROOT_DIR/scripts/build-hal-bundle.sh" "$CONFIGURATION"
"$ROOT_DIR/scripts/verify-hal-bundle.sh"
"$ROOT_DIR/scripts/build-helper-launch-agent.sh" \
    --helper "$ROOT_DIR/.build/$CONFIGURATION/HeartechoHelper"

"$ROOT_DIR/scripts/build-installer-pkg.sh" \
    --execute \
    --configuration "$CONFIGURATION" \
    --version "$VERSION_VALUE" \
    --output "$INSTALLER_PKG"
"$ROOT_DIR/scripts/verify-installer-pkg.sh" "$INSTALLER_PKG"

"$ROOT_DIR/scripts/build-uninstaller-pkg.sh" \
    --execute \
    --version "$VERSION_VALUE" \
    --output "$UNINSTALLER_PKG"
"$ROOT_DIR/scripts/verify-uninstaller-pkg.sh" "$UNINSTALLER_PKG"

"$ROOT_DIR/scripts/build-distribution-product.sh" \
    --execute \
    --version "$VERSION_VALUE" \
    --installer-pkg "$INSTALLER_PKG" \
    --uninstaller-pkg "$UNINSTALLER_PKG" \
    --output "$PRODUCT_PKG"
"$ROOT_DIR/scripts/verify-distribution-product.sh" "$PRODUCT_PKG"

"$ROOT_DIR/scripts/write-release-manifest.sh" \
    --configuration "$CONFIGURATION" \
    --version "$VERSION_VALUE" \
    --output "$MANIFEST_PATH"

printf 'Release artifacts ready\n'
printf '%s\n' "- installer: $INSTALLER_PKG"
printf '%s\n' "- uninstaller: $UNINSTALLER_PKG"
printf '%s\n' "- product: $PRODUCT_PKG"
printf '%s\n' "- manifest: $MANIFEST_PATH"
