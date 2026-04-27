#!/usr/bin/env bash
# Start MediaMTX in the foreground for monitoring.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -x bin/mediamtx ]]; then
    echo "!!! MediaMTX not found at bin/mediamtx"
    exit 1
fi

# Stop any running instance first
if pgrep -x mediamtx >/dev/null 2>&1; then
    echo "==> Stopping existing MediaMTX (PID $(pgrep -x mediamtx))..."
    pkill -x mediamtx
    sleep 1
fi

echo "==> Starting MediaMTX (foreground)..."
echo "    RTSP :8554 | RTMP :1935 | HLS :8888 | API :9997"
echo "    Press Ctrl+C to stop."
echo "---"
exec ./bin/mediamtx mediamtx.yml
