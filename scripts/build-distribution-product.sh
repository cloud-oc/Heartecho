#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="0.1.0"
PRODUCT_IDENTIFIER="com.heartecho.Heartecho.distribution"
INSTALLER_IDENTIFIER="com.heartecho.Heartecho.pkg"
UNINSTALLER_IDENTIFIER="com.heartecho.Heartecho.uninstaller.pkg"
OUTPUT_DIR="$ROOT_DIR/build/pkg"
INSTALLER_PKG=""
UNINSTALLER_PKG=""
PACKAGE_PATH=""
DISTRIBUTION_PATH=""
RESOURCES_DIR=""
EXECUTE=0
BUILD_COMPONENTS=0
SIGN_PKG_IDENTITY=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --execute)
            EXECUTE=1
            ;;
        --build-components)
            BUILD_COMPONENTS=1
            ;;
        --sign-pkg-identity)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --sign-pkg-identity\n' >&2; exit 64; }
            SIGN_PKG_IDENTITY="$1"
            ;;
        --version)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --version\n' >&2; exit 64; }
            VERSION="$1"
            ;;
        --identifier)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --identifier\n' >&2; exit 64; }
            PRODUCT_IDENTIFIER="$1"
            ;;
        --installer-pkg)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --installer-pkg\n' >&2; exit 64; }
            INSTALLER_PKG="$1"
            ;;
        --uninstaller-pkg)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --uninstaller-pkg\n' >&2; exit 64; }
            UNINSTALLER_PKG="$1"
            ;;
        --distribution)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --distribution\n' >&2; exit 64; }
            DISTRIBUTION_PATH="$1"
            ;;
        --resources)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --resources\n' >&2; exit 64; }
            RESOURCES_DIR="$1"
            ;;
        --output)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --output\n' >&2; exit 64; }
            PACKAGE_PATH="$1"
            ;;
        --help|-h)
            printf 'Usage: %s [--execute] [--build-components] [--sign-pkg-identity NAME] [--version VERSION] [--identifier ID] [--installer-pkg PATH] [--uninstaller-pkg PATH] [--distribution PATH] [--resources DIR] [--output PATH]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

if [ -z "$INSTALLER_PKG" ]; then
    INSTALLER_PKG="$OUTPUT_DIR/Heartecho-$VERSION.pkg"
fi

if [ -z "$UNINSTALLER_PKG" ]; then
    UNINSTALLER_PKG="$OUTPUT_DIR/Heartecho-Uninstaller-$VERSION.pkg"
fi

if [ -z "$PACKAGE_PATH" ]; then
    PACKAGE_PATH="$OUTPUT_DIR/Heartecho-Distribution-$VERSION.pkg"
fi

if [ -z "$DISTRIBUTION_PATH" ]; then
    DISTRIBUTION_PATH="$OUTPUT_DIR/Distribution.xml"
fi

if [ -z "$RESOURCES_DIR" ]; then
    RESOURCES_DIR="$OUTPUT_DIR/product-resources"
fi

component_status() {
    if [ -f "$1" ]; then
        printf 'present'
    else
        printf 'missing'
    fi
}

printf 'Heartecho distribution product workflow\n'
printf '%s\n' "- mode: $([ "$EXECUTE" -eq 1 ] && printf execute || printf dry-run)"
printf '%s\n' "- product package: $PACKAGE_PATH"
printf '%s\n' "- product identifier: $PRODUCT_IDENTIFIER"
printf '%s\n' "- version: $VERSION"
printf '%s\n' "- installer component: $INSTALLER_PKG ($(component_status "$INSTALLER_PKG"))"
printf '%s\n' "- uninstaller component: $UNINSTALLER_PKG ($(component_status "$UNINSTALLER_PKG"))"
printf '%s\n' "- build components first: $([ "$BUILD_COMPONENTS" -eq 1 ] && printf yes || printf no)"
printf '%s\n' "- distribution XML: $DISTRIBUTION_PATH"
printf '%s\n' "- resources: $RESOURCES_DIR"
printf '%s\n' "- package signing identity: $([ -n "$SIGN_PKG_IDENTITY" ] && printf '%s' "$SIGN_PKG_IDENTITY" || printf none)"
printf '%s' "- command: productbuild --distribution \"$DISTRIBUTION_PATH\" "
printf '%s ' "--package-path \"$(dirname "$INSTALLER_PKG")\""
printf '%s ' "--package-path \"$(dirname "$UNINSTALLER_PKG")\""
printf '%s ' "--resources \"$RESOURCES_DIR\""
if [ -n "$SIGN_PKG_IDENTITY" ]; then
    printf '%s ' "--sign \"$SIGN_PKG_IDENTITY\""
fi
printf '%s\n' "\"$PACKAGE_PATH\""

if [ "$EXECUTE" -ne 1 ]; then
    printf 'Dry run only. Re-run with --execute to generate the Distribution XML and build the product pkg.\n'
    exit 0
fi

if [ "$BUILD_COMPONENTS" -eq 1 ]; then
    if [ -n "$SIGN_PKG_IDENTITY" ]; then
        "$ROOT_DIR/scripts/build-installer-pkg.sh" \
            --execute \
            --version "$VERSION" \
            --identifier "$INSTALLER_IDENTIFIER" \
            --output "$INSTALLER_PKG" \
            --sign-pkg-identity "$SIGN_PKG_IDENTITY"

        "$ROOT_DIR/scripts/build-uninstaller-pkg.sh" \
            --execute \
            --version "$VERSION" \
            --identifier "$UNINSTALLER_IDENTIFIER" \
            --output "$UNINSTALLER_PKG" \
            --sign-pkg-identity "$SIGN_PKG_IDENTITY"
    else
        "$ROOT_DIR/scripts/build-installer-pkg.sh" \
            --execute \
            --version "$VERSION" \
            --identifier "$INSTALLER_IDENTIFIER" \
            --output "$INSTALLER_PKG"

        "$ROOT_DIR/scripts/build-uninstaller-pkg.sh" \
            --execute \
            --version "$VERSION" \
            --identifier "$UNINSTALLER_IDENTIFIER" \
            --output "$UNINSTALLER_PKG"
    fi
fi

[ -f "$INSTALLER_PKG" ] || { printf 'Missing installer component package: %s\n' "$INSTALLER_PKG" >&2; exit 1; }
[ -f "$UNINSTALLER_PKG" ] || { printf 'Missing uninstaller component package: %s\n' "$UNINSTALLER_PKG" >&2; exit 1; }

"$ROOT_DIR/scripts/verify-installer-pkg.sh" "$INSTALLER_PKG" >/dev/null
"$ROOT_DIR/scripts/verify-uninstaller-pkg.sh" "$UNINSTALLER_PKG" >/dev/null

mkdir -p "$OUTPUT_DIR" "$(dirname "$DISTRIBUTION_PATH")" "$RESOURCES_DIR"

INSTALLER_BASENAME="$(basename "$INSTALLER_PKG")"
UNINSTALLER_BASENAME="$(basename "$UNINSTALLER_PKG")"

cat >"$DISTRIBUTION_PATH" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Heartecho</title>
    <product id="$PRODUCT_IDENTIFIER" version="$VERSION"/>
    <options customize="always" require-scripts="true"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <choices-outline>
        <line choice="install"/>
        <line choice="uninstall"/>
    </choices-outline>
    <choice id="install" title="Install Heartecho" description="Install the app, HAL driver, helper, and LaunchAgent." selected="true">
        <pkg-ref id="$INSTALLER_IDENTIFIER"/>
    </choice>
    <choice id="uninstall" title="Uninstall Heartecho" description="Remove the app, HAL driver, helper, and LaunchAgent." selected="false">
        <pkg-ref id="$UNINSTALLER_IDENTIFIER"/>
    </choice>
    <pkg-ref id="$INSTALLER_IDENTIFIER" version="$VERSION" onConclusion="none">$INSTALLER_BASENAME</pkg-ref>
    <pkg-ref id="$UNINSTALLER_IDENTIFIER" version="$VERSION" onConclusion="none">$UNINSTALLER_BASENAME</pkg-ref>
</installer-gui-script>
EOF

cat >"$RESOURCES_DIR/ReadMe.txt" <<EOF
Heartecho $VERSION

This product package wraps the Heartecho installer and uninstaller component packages.

The installer component places:
- /Applications/Heartecho.app
- /Library/Audio/Plug-Ins/HAL/Heartecho.driver
- /Library/Application Support/Heartecho/HeartechoHelper
- /Library/LaunchAgents/com.heartecho.Heartecho.Helper.plist

Production distribution still requires Developer ID signing, notarization, stapling, and validation on an installed macOS system.
EOF

if [ -n "$SIGN_PKG_IDENTITY" ]; then
    productbuild \
        --distribution "$DISTRIBUTION_PATH" \
        --package-path "$(dirname "$INSTALLER_PKG")" \
        --package-path "$(dirname "$UNINSTALLER_PKG")" \
        --resources "$RESOURCES_DIR" \
        --sign "$SIGN_PKG_IDENTITY" \
        "$PACKAGE_PATH"
else
    productbuild \
        --distribution "$DISTRIBUTION_PATH" \
        --package-path "$(dirname "$INSTALLER_PKG")" \
        --package-path "$(dirname "$UNINSTALLER_PKG")" \
        --resources "$RESOURCES_DIR" \
        "$PACKAGE_PATH"
fi

printf 'Built %s\n' "$PACKAGE_PATH"
