#!/usr/bin/env bash
# Start all services: MediaMTX, fake streams, Go server.
# Usage: ./scripts/start.sh [--no-fake]   Skip fake cam1 stream
#        ./scripts/start.sh [--build]     Force rebuild before starting
set -euo pipefail
cd "$(dirname "$0")/.."

SKIP_FAKE=false
DO_BUILD=false
for arg in "$@"; do
    case "$arg" in
        --no-fake) SKIP_FAKE=true ;;
        --build)   DO_BUILD=true ;;
        -h|--help)
            echo "Usage: $0 [--no-fake] [--build]"
            echo "  --no-fake  Skip fake cam1 stream (use when all cameras are real)"
            echo "  --build    Force rebuild of Go server before starting"
            exit 0
            ;;
    esac
done

PIDS=()
cleanup() {
    echo ""
    echo "==> Shutting down..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    pkill -f 'ffmpeg.*smptebars.*cam1' 2>/dev/null || true
    wait 2>/dev/null || true
    echo "==> Stopped."
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# Build server if binary missing or --build requested
if [[ "$DO_BUILD" == true ]] || [[ ! -x bin/server ]]; then
    echo "==> Building Go server..."
    go build -o bin/server ./cmd/server/
fi

# Download MediaMTX if missing
if [[ ! -x bin/mediamtx ]]; then
    echo "==> MediaMTX not found, run 'make bin/mediamtx' first."
    exit 1
fi

# Start MediaMTX
echo "==> Starting MediaMTX..."
./bin/mediamtx mediamtx.yml > /dev/null 2>&1 &
PIDS+=($!)
sleep 2

# Verify MediaMTX is up
if ! curl -sf http://localhost:9997/v3/paths/list > /dev/null 2>&1; then
    echo "!!! MediaMTX failed to start"
    exit 1
fi
echo "    MediaMTX ready (RTSP :8554, RTMP :1935, HLS :8888, API :9997)"

# Start fake cam1 stream
if [[ "$SKIP_FAKE" == false ]]; then
    echo "==> Starting fake cam1 stream..."
    bash scripts/fake-streams.sh &
    PIDS+=($!)
    sleep 2
    echo "    cam1 fake stream running"
fi

# Start SSH reverse tunnels for RPi cameras
echo "==> Starting SSH tunnels for RPi cameras..."
ssh -R 1935:localhost:1935 -N -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes rpicam2 &
PIDS+=($!)
ssh -R 1935:localhost:1935 -N -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes rpicam3 &
PIDS+=($!)
sleep 1
echo "    SSH tunnels: rpicam2, rpicam3 → localhost:1935"

# Start Go server (foreground — Ctrl+C stops everything)
echo "==> Starting Go server on :8080..."
echo "    UI:  http://localhost:8080"
echo "    API: http://localhost:8080/api/status"
echo ""
echo "    cam1: fake SMPTE bars (RTSP)"
echo "    cam2: rpicam2 (RTMP via SSH tunnel)"
echo "    cam3: rpicam3 (RTMP via SSH tunnel)"
echo ""
echo "Press Ctrl+C to stop all services."
echo "---"
exec ./bin/server
