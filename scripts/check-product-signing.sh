#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="0.1.0"
APP_DIR="$ROOT_DIR/build/App/Heartecho.app"
HAL_BUNDLE="$ROOT_DIR/build/HAL/Heartecho.driver"
HELPER_PATH="$ROOT_DIR/.build/debug/HeartechoHelper"
INSTALLER_PKG="$ROOT_DIR/build/pkg/Heartecho-$VERSION.pkg"
UNINSTALLER_PKG="$ROOT_DIR/build/pkg/Heartecho-Uninstaller-$VERSION.pkg"
PRODUCT_PKG="$ROOT_DIR/build/pkg/Heartecho-Distribution-$VERSION.pkg"
REQUIRE_VALID=0
FAILURES=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --require-valid)
            REQUIRE_VALID=1
            ;;
        --version)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --version\n' >&2; exit 64; }
            VERSION="$1"
            INSTALLER_PKG="$ROOT_DIR/build/pkg/Heartecho-$VERSION.pkg"
            UNINSTALLER_PKG="$ROOT_DIR/build/pkg/Heartecho-Uninstaller-$VERSION.pkg"
            PRODUCT_PKG="$ROOT_DIR/build/pkg/Heartecho-Distribution-$VERSION.pkg"
            ;;
        --app)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --app\n' >&2; exit 64; }
            APP_DIR="$1"
            ;;
        --hal)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --hal\n' >&2; exit 64; }
            HAL_BUNDLE="$1"
            ;;
        --helper)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --helper\n' >&2; exit 64; }
            HELPER_PATH="$1"
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
        --product-pkg)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --product-pkg\n' >&2; exit 64; }
            PRODUCT_PKG="$1"
            ;;
        --help|-h)
            printf 'Usage: %s [--require-valid] [--version VERSION] [--app PATH] [--hal PATH] [--helper PATH] [--installer-pkg PATH] [--uninstaller-pkg PATH] [--product-pkg PATH]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

record_failure() {
    if [ "$REQUIRE_VALID" -eq 1 ]; then
        FAILURES=$((FAILURES + 1))
    fi
}

print_codesign_target() {
    label="$1"
    path="$2"
    developer_id_valid=0

    printf '%s\n' "$label"
    printf '%s\n' "- path: $path"
    if [ ! -e "$path" ]; then
        printf '%s\n' "- exists: no"
        printf '%s\n' "- signature: missing"
        record_failure
        return
    fi

    printf '%s\n' "- exists: yes"
    if codesign -dv "$path" >/tmp/heartecho-signing-details.log 2>&1; then
        true
    else
        true
    fi

    if codesign --verify --strict --verbose=2 "$path" >/tmp/heartecho-signing-check.log 2>&1; then
        if grep -q '^Authority=Developer ID Application:' /tmp/heartecho-signing-details.log \
            && ! grep -q '^Signature=adhoc$' /tmp/heartecho-signing-details.log \
            && ! grep -q '^TeamIdentifier=not set$' /tmp/heartecho-signing-details.log; then
            developer_id_valid=1
            printf '%s\n' "- signature: valid Developer ID Application"
        else
            printf '%s\n' "- signature: valid but not Developer ID Application"
            record_failure
        fi
    else
        printf '%s\n' "- signature: missing or invalid"
        sed 's/^/  /' /tmp/heartecho-signing-check.log
        record_failure
    fi

    if [ "$REQUIRE_VALID" -eq 1 ] && [ "$developer_id_valid" -ne 1 ]; then
        printf '%s\n' "- release gate: failed"
    fi

    printf '%s\n' "- details:"
    sed 's/^/  /' /tmp/heartecho-signing-details.log
}

print_pkg_target() {
    label="$1"
    path="$2"
    developer_id_valid=0

    printf '%s\n' "$label"
    printf '%s\n' "- path: $path"
    if [ ! -f "$path" ]; then
        printf '%s\n' "- exists: no"
        printf '%s\n' "- signature: missing"
        record_failure
        return
    fi

    printf '%s\n' "- exists: yes"
    if pkgutil --check-signature "$path" >/tmp/heartecho-pkg-signing-check.log 2>&1; then
        if grep -q 'Developer ID Installer:' /tmp/heartecho-pkg-signing-check.log; then
            developer_id_valid=1
            printf '%s\n' "- signature: valid Developer ID Installer"
        else
            printf '%s\n' "- signature: valid but not Developer ID Installer"
            record_failure
        fi
    else
        printf '%s\n' "- signature: missing or invalid"
        record_failure
    fi
    if [ "$REQUIRE_VALID" -eq 1 ] && [ "$developer_id_valid" -ne 1 ]; then
        printf '%s\n' "- release gate: failed"
    fi
    sed 's/^/  /' /tmp/heartecho-pkg-signing-check.log
}

printf 'Heartecho signing report\n'
printf '%s\n' "- require valid: $([ "$REQUIRE_VALID" -eq 1 ] && printf yes || printf no)"

print_codesign_target "App bundle" "$APP_DIR"
print_codesign_target "HAL driver" "$HAL_BUNDLE"
print_codesign_target "Helper executable" "$HELPER_PATH"
print_pkg_target "Installer package" "$INSTALLER_PKG"
print_pkg_target "Uninstaller package" "$UNINSTALLER_PKG"
print_pkg_target "Distribution product package" "$PRODUCT_PKG"

printf '%s\n' "- failures: $FAILURES"

if [ "$REQUIRE_VALID" -eq 1 ] && [ "$FAILURES" -gt 0 ]; then
    exit 1
fi
