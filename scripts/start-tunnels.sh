#!/usr/bin/env bash
# Start SSH reverse tunnels for RPi cameras.
# Usage: ./scripts/start-tunnels.sh [rpicam2] [rpicam3] ...
#        ./scripts/start-tunnels.sh              (defaults to rpicam2 rpicam3)
set -euo pipefail
cd "$(dirname "$0")/.."

CAMS=("${@:-rpicam2 rpicam3}")
if [[ $# -eq 0 ]]; then
    CAMS=(rpicam2 rpicam3)
fi

PIDS=()
cleanup() {
    echo ""
    echo "==> Closing SSH tunnels..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    echo "==> Stopped."
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# Wait for MediaMTX RTMP port
echo "==> Waiting for RTMP on localhost:1935..."
for i in $(seq 1 30); do
    if lsof -i :1935 -sTCP:LISTEN > /dev/null 2>&1; then
        echo "    Port 1935 ready."
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "!!! Port 1935 not listening. Start MediaMTX first."
        exit 1
    fi
    sleep 1
done

for cam in "${CAMS[@]}"; do
    echo "==> Tunnel: ${cam} → localhost:1935"
    ssh -R 1935:localhost:1935 -N -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes "$cam" &
    PIDS+=($!)
done

echo "==> ${#CAMS[@]} tunnels active. Press Ctrl+C to stop."
wait
