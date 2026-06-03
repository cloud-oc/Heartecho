#!/bin/sh
set -u

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="0.1.0"
REPORT_PATH="$ROOT_DIR/build/release-preflight-report.txt"
REQUIRE_SIGNED=0
SKIP_SHARED_MEMORY=1
NOTARY_PROFILE=""
NODE_CHECK=1

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --version\n' >&2; exit 64; }
            VERSION="$1"
            ;;
        --report)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --report\n' >&2; exit 64; }
            REPORT_PATH="$1"
            ;;
        --require-signed)
            REQUIRE_SIGNED=1
            ;;
        --include-shared-memory)
            SKIP_SHARED_MEMORY=0
            ;;
        --notary-profile)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --notary-profile\n' >&2; exit 64; }
            NOTARY_PROFILE="$1"
            ;;
        --skip-vscode-json)
            NODE_CHECK=0
            ;;
        --help|-h)
            printf 'Usage: %s [--version VERSION] [--report PATH] [--require-signed] [--include-shared-memory] [--notary-profile NAME] [--skip-vscode-json]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
CURRENT_LOG="$ROOT_DIR/build/release-preflight-current.log"
INSTALLER_PKG="$ROOT_DIR/build/pkg/Heartecho-$VERSION.pkg"
UNINSTALLER_PKG="$ROOT_DIR/build/pkg/Heartecho-Uninstaller-$VERSION.pkg"
PRODUCT_PKG="$ROOT_DIR/build/pkg/Heartecho-Distribution-$VERSION.pkg"

mkdir -p "$(dirname "$REPORT_PATH")" "$CLANG_MODULE_CACHE_PATH"
: >"$REPORT_PATH"

append_report() {
    printf '%s\n' "$1" >>"$REPORT_PATH"
}

print_header() {
    printf 'Heartecho release preflight\n' | tee -a "$REPORT_PATH"
    printf '%s\n' "- root: $ROOT_DIR" | tee -a "$REPORT_PATH"
    printf '%s\n' "- version: $VERSION" | tee -a "$REPORT_PATH"
    printf '%s\n' "- report: $REPORT_PATH" | tee -a "$REPORT_PATH"
    printf '%s\n' "- require signed: $([ "$REQUIRE_SIGNED" -eq 1 ] && printf yes || printf no)" | tee -a "$REPORT_PATH"
    printf '%s\n' "- shared memory diagnostics: $([ "$SKIP_SHARED_MEMORY" -eq 1 ] && printf skipped || printf included)" | tee -a "$REPORT_PATH"
    printf '%s\n' "- system changes: none" | tee -a "$REPORT_PATH"
}

run_step() {
    LABEL="$1"
    shift

    printf '\n== %s ==\n' "$LABEL" | tee -a "$REPORT_PATH"
    append_report "command: $*"
    "$@" >"$CURRENT_LOG" 2>&1
    STATUS=$?
    cat "$CURRENT_LOG"
    cat "$CURRENT_LOG" >>"$REPORT_PATH"
    rm -f "$CURRENT_LOG"

    if [ "$STATUS" -ne 0 ]; then
        printf 'FAILED: %s (exit %s)\n' "$LABEL" "$STATUS" | tee -a "$REPORT_PATH" >&2
        exit "$STATUS"
    fi

    printf 'OK: %s\n' "$LABEL" | tee -a "$REPORT_PATH"
}

run_optional_step() {
    LABEL="$1"
    shift

    printf '\n== %s ==\n' "$LABEL" | tee -a "$REPORT_PATH"
    if "$@" >"$CURRENT_LOG" 2>&1; then
        cat "$CURRENT_LOG"
        cat "$CURRENT_LOG" >>"$REPORT_PATH"
        rm -f "$CURRENT_LOG"
        printf 'OK: %s\n' "$LABEL" | tee -a "$REPORT_PATH"
    else
        STATUS=$?
        cat "$CURRENT_LOG"
        cat "$CURRENT_LOG" >>"$REPORT_PATH"
        rm -f "$CURRENT_LOG"
        printf 'SKIPPED/FAILED OPTIONAL: %s (exit %s)\n' "$LABEL" "$STATUS" | tee -a "$REPORT_PATH"
    fi
}

artifact_line() {
    LABEL="$1"
    PATH_VALUE="$2"

    if [ -d "$PATH_VALUE" ]; then
        printf '%s\n' "- $LABEL: $PATH_VALUE (directory)" | tee -a "$REPORT_PATH"
    elif [ -f "$PATH_VALUE" ]; then
        printf '%s\n' "- $LABEL: $PATH_VALUE (file)" | tee -a "$REPORT_PATH"
    else
        printf '%s\n' "- $LABEL: $PATH_VALUE (missing)" | tee -a "$REPORT_PATH"
    fi
}

print_manifest() {
    printf '\n== Artifact Manifest ==\n' | tee -a "$REPORT_PATH"
    artifact_line "app bundle" "$ROOT_DIR/build/App/Heartecho.app"
    artifact_line "HAL driver bundle" "$ROOT_DIR/build/HAL/Heartecho.driver"
    artifact_line "helper executable" "$ROOT_DIR/.build/debug/HeartechoHelper"
    artifact_line "helper LaunchAgent plist" "$ROOT_DIR/build/launchd/com.heartecho.Heartecho.Helper.plist"
    artifact_line "installer package" "$INSTALLER_PKG"
    artifact_line "uninstaller package" "$UNINSTALLER_PKG"
    artifact_line "distribution product package" "$PRODUCT_PKG"
}

DIAGNOSTIC_ARGS=""
if [ "$SKIP_SHARED_MEMORY" -eq 1 ]; then
    DIAGNOSTIC_ARGS="--skip-shared-memory"
fi

SIGNING_ARGS=""
MANIFEST_ARGS=""
if [ "$REQUIRE_SIGNED" -eq 1 ]; then
    SIGNING_ARGS="--require-valid"
    MANIFEST_ARGS="--require-signed"
fi

print_header

run_step "Swift toolchain check" "$ROOT_DIR/scripts/check-swift-toolchain.sh"

run_step "Swift build" \
    env CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" swift build --disable-sandbox

run_step "Build icon assets" "$ROOT_DIR/scripts/build-icons.sh"

run_step "Build app bundle" "$ROOT_DIR/scripts/build-app-bundle.sh" debug
run_step "Verify app bundle" "$ROOT_DIR/scripts/verify-app-bundle.sh"

run_step "Build HAL bundle" "$ROOT_DIR/scripts/build-hal-bundle.sh" debug
run_step "Verify HAL bundle" "$ROOT_DIR/scripts/verify-hal-bundle.sh"

run_step "Build helper LaunchAgent plist" "$ROOT_DIR/scripts/build-helper-launch-agent.sh"

if [ "$NODE_CHECK" -eq 1 ]; then
    if command -v node >/dev/null 2>&1; then
        run_step "Validate VSCode tasks JSON" node -e "JSON.parse(require('fs').readFileSync('$ROOT_DIR/.vscode/tasks.json','utf8')); console.log('tasks.json OK')"
    else
        printf '\n== Validate VSCode tasks JSON ==\n' | tee -a "$REPORT_PATH"
        printf 'Skipped because node is not installed.\n' | tee -a "$REPORT_PATH"
    fi
fi

# shellcheck disable=SC2086
run_step "Sandbox-safe diagnostics" \
    env CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" swift run --disable-sandbox HeartechoDiagnostics $DIAGNOSTIC_ARGS

run_step "Helper recovery dry-run" "$ROOT_DIR/scripts/recover-helper-service.sh" --kickstart

run_step "Build installer package" "$ROOT_DIR/scripts/build-installer-pkg.sh" --execute --version "$VERSION" --output "$INSTALLER_PKG"
run_step "Verify installer package" "$ROOT_DIR/scripts/verify-installer-pkg.sh" "$INSTALLER_PKG"

run_step "Build uninstaller package" "$ROOT_DIR/scripts/build-uninstaller-pkg.sh" --execute --version "$VERSION" --output "$UNINSTALLER_PKG"
run_step "Verify uninstaller package" "$ROOT_DIR/scripts/verify-uninstaller-pkg.sh" "$UNINSTALLER_PKG"

run_step "Build distribution product package" "$ROOT_DIR/scripts/build-distribution-product.sh" --execute --version "$VERSION" --installer-pkg "$INSTALLER_PKG" --uninstaller-pkg "$UNINSTALLER_PKG" --output "$PRODUCT_PKG"
run_step "Verify distribution product package" "$ROOT_DIR/scripts/verify-distribution-product.sh" "$PRODUCT_PKG"

# shellcheck disable=SC2086
run_step "Check product signing" "$ROOT_DIR/scripts/check-product-signing.sh" $SIGNING_ARGS --version "$VERSION"

# shellcheck disable=SC2086
run_step "Write release manifest" "$ROOT_DIR/scripts/write-release-manifest.sh" $MANIFEST_ARGS --version "$VERSION"

if [ -n "$NOTARY_PROFILE" ]; then
    run_optional_step "HAL notarization dry-run" "$ROOT_DIR/scripts/notarize-hal-bundle.sh" --keychain-profile "$NOTARY_PROFILE"
    run_optional_step "Product notarization dry-run" "$ROOT_DIR/scripts/notarize-product-pkg.sh" --keychain-profile "$NOTARY_PROFILE" --package "$PRODUCT_PKG"
fi

print_manifest

printf '\nRelease preflight completed.\n' | tee -a "$REPORT_PATH"
printf '%s\n' "- report: $REPORT_PATH" | tee -a "$REPORT_PATH"
if [ "$REQUIRE_SIGNED" -eq 0 ]; then
    printf 'Unsigned artifacts are reported but not treated as failures. Use --require-signed for the release gate.\n' | tee -a "$REPORT_PATH"
fi
