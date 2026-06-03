#!/bin/sh
set -eu

EXECUTE=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --execute)
            EXECUTE=1
            ;;
        --help|-h)
            printf 'Usage: %s [--execute]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

printf 'Core Audio reload plan\n'
printf '%s\n' '- command: killall coreaudiod'
printf '%s\n' "- mode: $([ "$EXECUTE" -eq 1 ] && printf execute || printf dry-run)"

if [ "$EXECUTE" -ne 1 ]; then
    printf 'Dry run only. Re-run with --execute to ask macOS to restart coreaudiod.\n'
    exit 0
fi

killall coreaudiod
printf 'Requested coreaudiod restart.\n'
