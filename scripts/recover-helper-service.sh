#!/bin/sh
set -eu

LABEL="com.heartecho.Heartecho.Helper"
USER_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
SYSTEM_AGENT="/Library/LaunchAgents/$LABEL.plist"
AGENT_PATH=""
EXECUTE=0
SCOPE="gui/$(id -u)"
ACTION="plan"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --plist)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --plist\n' >&2; exit 64; }
            AGENT_PATH="$1"
            ;;
        --label)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --label\n' >&2; exit 64; }
            LABEL="$1"
            ;;
        --system)
            SCOPE="system"
            ;;
        --kickstart)
            ACTION="kickstart"
            ;;
        --restart)
            ACTION="restart"
            ;;
        --execute)
            EXECUTE=1
            ;;
        --help|-h)
            printf 'Usage: %s [--plist PATH] [--label LABEL] [--system] [--kickstart|--restart] [--execute]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

if [ -z "$AGENT_PATH" ]; then
    if [ -f "$SYSTEM_AGENT" ]; then
        AGENT_PATH="$SYSTEM_AGENT"
        SCOPE="system"
    elif [ -f "$USER_AGENT" ]; then
        AGENT_PATH="$USER_AGENT"
    else
        AGENT_PATH="$USER_AGENT"
    fi
fi

SERVICE_TARGET="$SCOPE/$LABEL"

printf 'Helper service recovery plan\n'
printf '%s\n' "- label: $LABEL"
printf '%s\n' "- plist: $AGENT_PATH"
printf '%s\n' "- scope: $SCOPE"
printf '%s\n' "- action: $ACTION"
printf '%s\n' "- mode: $([ "$EXECUTE" -eq 1 ] && printf execute || printf dry-run)"
printf '%s\n' "- plist exists: $([ -f "$AGENT_PATH" ] && printf yes || printf no)"

if [ -f "$AGENT_PATH" ]; then
    if plutil -lint "$AGENT_PATH" >/dev/null 2>&1; then
        printf '%s\n' "- plist valid: yes"
    else
        printf '%s\n' "- plist valid: no"
    fi

    HELPER_PATH="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$AGENT_PATH" 2>/dev/null || true)"
    printf '%s\n' "- helper: ${HELPER_PATH:-unknown}"
    printf '%s\n' "- helper executable: $([ -n "$HELPER_PATH" ] && [ -x "$HELPER_PATH" ] && printf yes || printf no)"
    if [ -n "$HELPER_PATH" ] && codesign --verify --strict "$HELPER_PATH" >/dev/null 2>&1; then
        printf '%s\n' "- helper signature: valid"
    else
        printf '%s\n' "- helper signature: missing or invalid"
    fi
else
    printf 'No LaunchAgent plist is installed. Build/install the helper LaunchAgent before recovery can run.\n'
fi

if launchctl print "$SERVICE_TARGET" >/dev/null 2>&1; then
    printf '%s\n' "- launchd state: loaded"
else
    printf '%s\n' "- launchd state: not loaded"
fi

printf 'Planned commands\n'
case "$ACTION" in
    kickstart)
        printf '%s\n' "launchctl kickstart -k \"$SERVICE_TARGET\""
        ;;
    restart)
        printf '%s\n' "launchctl bootout \"$SCOPE\" \"$AGENT_PATH\" || true"
        printf '%s\n' "launchctl bootstrap \"$SCOPE\" \"$AGENT_PATH\""
        ;;
    *)
        printf '%s\n' "launchctl print \"$SERVICE_TARGET\""
        printf '%s\n' "launchctl kickstart -k \"$SERVICE_TARGET\""
        ;;
esac

if [ "$EXECUTE" -ne 1 ]; then
    printf 'Dry run only. Re-run with --execute after signing/install validation to perform the selected recovery action.\n'
    exit 0
fi

[ -f "$AGENT_PATH" ] || { printf 'Cannot recover without plist: %s\n' "$AGENT_PATH" >&2; exit 1; }
plutil -lint "$AGENT_PATH" >/dev/null

case "$ACTION" in
    kickstart)
        launchctl kickstart -k "$SERVICE_TARGET"
        ;;
    restart)
        launchctl bootout "$SCOPE" "$AGENT_PATH" 2>/dev/null || true
        launchctl bootstrap "$SCOPE" "$AGENT_PATH"
        ;;
    *)
        launchctl print "$SERVICE_TARGET"
        ;;
esac
