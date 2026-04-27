#!/usr/bin/env bash
# Start MediaMTX in the foreground for monitoring.
# Also starts fake cam1 stream.
# Usage: ./scripts/start-mediamtx.sh [--no-fake]
set -euo pipefail
cd "$(dirname "$0")/.."

SKIP_FAKE=false
for arg in "$@"; do
    case "$arg" in
        --no-fake) SKIP_FAKE=true ;;
        -h|--help)
            echo "Usage: $0 [--no-fake]"
            echo "  --no-fake  Skip fake cam1 stream"
            exit 0
            ;;
    esac
done

if [[ ! -x bin/mediamtx ]]; then
    echo "!!! MediaMTX not found at bin/mediamtx"
    exit 1
fi

PIDS=()
cleanup() {
    echo ""
    echo "==> Shutting down MediaMTX + helpers..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    pkill -f 'ffmpeg.*smptebars.*cam1' 2>/dev/null || true
    wait 2>/dev/null || true
    echo "==> Stopped."
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# Start fake cam1 stream
if [[ "$SKIP_FAKE" == false ]]; then
    echo "==> Starting fake cam1 stream..."
    bash scripts/fake-streams.sh &
    PIDS+=($!)
fi

echo "==> Starting MediaMTX (foreground)..."
echo "    RTSP :8554 | RTMP :1935 | HLS :8888 | API :9997"
echo "    Press Ctrl+C to stop."
echo "---"
exec ./bin/mediamtx mediamtx.yml
