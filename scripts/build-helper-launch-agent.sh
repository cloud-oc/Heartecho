#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER_PATH="$ROOT_DIR/.build/debug/HeartechoHelper"
GRAPH_PATH="$HOME/Library/Application Support/Heartecho/RoutingGraph.json"
CONFIG_SHM="/HeartechoHALSharedConfig"
AUDIO_SHM="/HeartechoHALAudioBuffers"
LABEL="com.heartecho.Heartecho.Helper"
OUTPUT_DIR="$ROOT_DIR/build/launchd"
OUTPUT_PATH=""
INTERVAL_MS=10
FRAME_COUNT=512

while [ "$#" -gt 0 ]; do
    case "$1" in
        --helper)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --helper\n' >&2; exit 64; }
            HELPER_PATH="$1"
            ;;
        --graph)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --graph\n' >&2; exit 64; }
            GRAPH_PATH="$1"
            ;;
        --config-shm)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --config-shm\n' >&2; exit 64; }
            CONFIG_SHM="$1"
            ;;
        --audio-shm)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --audio-shm\n' >&2; exit 64; }
            AUDIO_SHM="$1"
            ;;
        --label)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --label\n' >&2; exit 64; }
            LABEL="$1"
            ;;
        --output)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --output\n' >&2; exit 64; }
            OUTPUT_PATH="$1"
            ;;
        --interval-ms)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --interval-ms\n' >&2; exit 64; }
            INTERVAL_MS="$1"
            ;;
        --frames)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --frames\n' >&2; exit 64; }
            FRAME_COUNT="$1"
            ;;
        --help|-h)
            printf 'Usage: %s [--helper PATH] [--graph PATH] [--config-shm NAME] [--audio-shm NAME] [--label LABEL] [--output PATH] [--frames COUNT] [--interval-ms COUNT]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

case "$CONFIG_SHM" in
    /*) ;;
    *) printf 'Config shared-memory name must start with /: %s\n' "$CONFIG_SHM" >&2; exit 64 ;;
esac

case "$AUDIO_SHM" in
    /*) ;;
    *) printf 'Audio shared-memory name must start with /: %s\n' "$AUDIO_SHM" >&2; exit 64 ;;
esac

case "$INTERVAL_MS" in
    ''|*[!0-9]*) printf 'Interval must be a positive integer: %s\n' "$INTERVAL_MS" >&2; exit 64 ;;
    0) printf 'Interval must be greater than zero.\n' >&2; exit 64 ;;
esac

case "$FRAME_COUNT" in
    ''|*[!0-9]*) printf 'Frame count must be a positive integer: %s\n' "$FRAME_COUNT" >&2; exit 64 ;;
    0) printf 'Frame count must be greater than zero.\n' >&2; exit 64 ;;
esac

if [ -z "$OUTPUT_PATH" ]; then
    OUTPUT_PATH="$OUTPUT_DIR/$LABEL.plist"
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

cat >"$OUTPUT_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HELPER_PATH</string>
        <string>--graph</string>
        <string>$GRAPH_PATH</string>
        <string>--publish-audio</string>
        <string>--serve</string>
        <string>--frames</string>
        <string>$FRAME_COUNT</string>
        <string>--interval-ms</string>
        <string>$INTERVAL_MS</string>
        <string>--config-shm</string>
        <string>$CONFIG_SHM</string>
        <string>--audio-shm</string>
        <string>$AUDIO_SHM</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/HeartechoHelper.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/HeartechoHelper.err.log</string>
</dict>
</plist>
EOF

plutil -lint "$OUTPUT_PATH" >/dev/null

printf 'Helper LaunchAgent plist\n'
printf '%s\n' "- output: $OUTPUT_PATH"
printf '%s\n' "- label: $LABEL"
printf '%s\n' "- helper: $HELPER_PATH"
printf '%s\n' "- graph: $GRAPH_PATH"
printf '%s\n' "- interval: $INTERVAL_MS ms"
printf '%s\n' "- frames: $FRAME_COUNT"
printf 'Dry-run artifact only. Copy to ~/Library/LaunchAgents and load with launchctl only after signing/install work is complete.\n'
