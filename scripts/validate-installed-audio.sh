#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WAIT_SECONDS=30
ITERATIONS=3
INTERVAL_SECONDS=5
REPORT_PATH="$ROOT_DIR/build/installed-audio-validation-report.txt"
STRICT=0
SKIP_SHARED_MEMORY=0
BUILD_FIRST=0
PREPARE_PROCESS_TAP=0
PREPARE_HARDWARE_INPUT=0
START_MONITOR_PLAYBACK=0
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
CURRENT_LOG="$ROOT_DIR/build/installed-audio-validation-current.log"
FAILURES=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --wait)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --wait\n' >&2; exit 64; }
            WAIT_SECONDS="$1"
            ;;
        --iterations)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --iterations\n' >&2; exit 64; }
            ITERATIONS="$1"
            ;;
        --interval)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --interval\n' >&2; exit 64; }
            INTERVAL_SECONDS="$1"
            ;;
        --report)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --report\n' >&2; exit 64; }
            REPORT_PATH="$1"
            ;;
        --strict)
            STRICT=1
            ;;
        --skip-shared-memory)
            SKIP_SHARED_MEMORY=1
            ;;
        --build)
            BUILD_FIRST=1
            ;;
        --prepare-process-tap)
            PREPARE_PROCESS_TAP=1
            ;;
        --prepare-hardware-input)
            PREPARE_HARDWARE_INPUT=1
            ;;
        --start-monitor-playback)
            START_MONITOR_PLAYBACK=1
            ;;
        --help|-h)
            printf 'Usage: %s [--wait SECONDS] [--iterations N] [--interval SECONDS] [--report PATH] [--strict] [--skip-shared-memory] [--build] [--prepare-process-tap] [--prepare-hardware-input] [--start-monitor-playback]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

case "$WAIT_SECONDS" in ''|*[!0-9]*) printf 'Wait seconds must be a non-negative integer: %s\n' "$WAIT_SECONDS" >&2; exit 64 ;; esac
case "$ITERATIONS" in ''|*[!0-9]*) printf 'Iterations must be a non-negative integer: %s\n' "$ITERATIONS" >&2; exit 64 ;; esac
case "$INTERVAL_SECONDS" in ''|*[!0-9]*) printf 'Interval seconds must be a non-negative integer: %s\n' "$INTERVAL_SECONDS" >&2; exit 64 ;; esac

mkdir -p "$(dirname "$REPORT_PATH")" "$CLANG_MODULE_CACHE_PATH"
: >"$REPORT_PATH"

append_report() {
    printf '%s\n' "$1" >>"$REPORT_PATH"
}

record_failure() {
    FAILURES=$((FAILURES + 1))
    printf '%s\n' "Validation failure: $1" | tee -a "$REPORT_PATH"
}

run_step() {
    LABEL="$1"
    shift

    printf '\n== %s ==\n' "$LABEL" | tee -a "$REPORT_PATH"
    append_report "command: $*"
    if "$@" >"$CURRENT_LOG" 2>&1; then
        STATUS=0
    else
        STATUS=$?
    fi
    cat "$CURRENT_LOG"
    cat "$CURRENT_LOG" >>"$REPORT_PATH"
    rm -f "$CURRENT_LOG"

    if [ "$STATUS" -ne 0 ]; then
        record_failure "$LABEL exited with $STATUS"
        return "$STATUS"
    fi

    printf 'OK: %s\n' "$LABEL" | tee -a "$REPORT_PATH"
    return 0
}

run_nonfatal_step() {
    LABEL="$1"
    shift
    run_step "$LABEL" "$@" || true
}

diagnostic_command() {
    EXTRA_ARGS="--wait-hal-device $WAIT_SECONDS"
    if [ "$SKIP_SHARED_MEMORY" -eq 1 ]; then
        EXTRA_ARGS="$EXTRA_ARGS --skip-shared-memory"
    fi
    if [ "$PREPARE_PROCESS_TAP" -eq 1 ]; then
        EXTRA_ARGS="$EXTRA_ARGS --prepare-process-tap"
    fi
    if [ "$PREPARE_HARDWARE_INPUT" -eq 1 ]; then
        EXTRA_ARGS="$EXTRA_ARGS --prepare-hardware-input"
    fi
    if [ "$START_MONITOR_PLAYBACK" -eq 1 ]; then
        EXTRA_ARGS="$EXTRA_ARGS --start-monitor-playback"
    fi

    if [ -x "$ROOT_DIR/.build/debug/HeartechoDiagnostics" ]; then
        # shellcheck disable=SC2086
        "$ROOT_DIR/.build/debug/HeartechoDiagnostics" $EXTRA_ARGS
    else
        # shellcheck disable=SC2086
        env CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" swift run --disable-sandbox HeartechoDiagnostics $EXTRA_ARGS
    fi
}

run_diagnostics_iteration() {
    LABEL="$1"
    printf '\n== %s ==\n' "$LABEL" | tee -a "$REPORT_PATH"
    append_report "command: HeartechoDiagnostics --wait-hal-device $WAIT_SECONDS"
    if diagnostic_command >"$CURRENT_LOG" 2>&1; then
        STATUS=0
    else
        STATUS=$?
    fi
    cat "$CURRENT_LOG"
    cat "$CURRENT_LOG" >>"$REPORT_PATH"

    if [ "$STATUS" -ne 0 ]; then
        rm -f "$CURRENT_LOG"
        record_failure "$LABEL exited with $STATUS"
        return 0
    fi

    if ! sed -n 's/^- HAL visibility wait: //p' "$CURRENT_LOG" | tail -1 | grep -q '^visible'; then
        record_failure "$LABEL did not observe a Core Audio-visible Heartecho virtual device"
    fi

    if ! sed -n 's/^- Audio readiness report: //p' "$CURRENT_LOG" | tail -1 | grep -q '^Ready /'; then
        record_failure "$LABEL audio readiness was not Ready"
    fi

    if [ "$SKIP_SHARED_MEMORY" -eq 0 ]; then
        if ! grep -q '^- HAL audio shared memory publication: OK$' "$CURRENT_LOG"; then
            record_failure "$LABEL did not verify HAL audio shared-memory publication"
        fi
        if ! grep -q '^- HAL audio live shared memory transport: OK$' "$CURRENT_LOG"; then
            record_failure "$LABEL did not verify live HAL audio shared-memory transport"
        fi
    fi

    rm -f "$CURRENT_LOG"
    printf 'Recorded: %s\n' "$LABEL" | tee -a "$REPORT_PATH"
}

printf 'Heartecho installed audio validation\n' | tee -a "$REPORT_PATH"
printf '%s\n' "- root: $ROOT_DIR" | tee -a "$REPORT_PATH"
printf '%s\n' "- report: $REPORT_PATH" | tee -a "$REPORT_PATH"
printf '%s\n' "- strict: $([ "$STRICT" -eq 1 ] && printf yes || printf no)" | tee -a "$REPORT_PATH"
printf '%s\n' "- wait seconds: $WAIT_SECONDS" | tee -a "$REPORT_PATH"
printf '%s\n' "- iterations: $ITERATIONS" | tee -a "$REPORT_PATH"
printf '%s\n' "- interval seconds: $INTERVAL_SECONDS" | tee -a "$REPORT_PATH"
printf '%s\n' "- shared memory: $([ "$SKIP_SHARED_MEMORY" -eq 1 ] && printf skipped || printf included)" | tee -a "$REPORT_PATH"
printf '%s\n' "- process tap prepare probe: $([ "$PREPARE_PROCESS_TAP" -eq 1 ] && printf enabled || printf disabled)" | tee -a "$REPORT_PATH"
printf '%s\n' "- hardware input prepare probe: $([ "$PREPARE_HARDWARE_INPUT" -eq 1 ] && printf enabled || printf disabled)" | tee -a "$REPORT_PATH"
printf '%s\n' "- monitor playback probe: $([ "$START_MONITOR_PLAYBACK" -eq 1 ] && printf enabled || printf disabled)" | tee -a "$REPORT_PATH"
printf '%s\n' "- system changes: none" | tee -a "$REPORT_PATH"

if [ "$BUILD_FIRST" -eq 1 ]; then
    run_nonfatal_step "Build diagnostics" \
        env CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" swift build --disable-sandbox
fi

run_nonfatal_step "Installed payload validation" \
    "$ROOT_DIR/scripts/validate-installation.sh" --strict --wait "$WAIT_SECONDS"

if [ "$ITERATIONS" -eq 0 ]; then
    printf '\nDiagnostics iterations skipped.\n' | tee -a "$REPORT_PATH"
else
    i=1
    while [ "$i" -le "$ITERATIONS" ]; do
        run_diagnostics_iteration "Installed audio diagnostics iteration $i of $ITERATIONS"
        if [ "$i" -lt "$ITERATIONS" ] && [ "$INTERVAL_SECONDS" -gt 0 ]; then
            sleep "$INTERVAL_SECONDS"
        fi
        i=$((i + 1))
    done
fi

printf '\nInstalled audio validation completed.\n' | tee -a "$REPORT_PATH"
printf '%s\n' "- failures: $FAILURES" | tee -a "$REPORT_PATH"
printf '%s\n' "- report: $REPORT_PATH" | tee -a "$REPORT_PATH"

if [ "$STRICT" -eq 1 ] && [ "$FAILURES" -gt 0 ]; then
    exit 1
fi

exit 0
