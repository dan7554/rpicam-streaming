#!/usr/bin/env bash
# Start local dev stack: MediaMTX + Go server.
# Cameras push RTMP directly to this Mac via Tailscale.
#
# Usage: ./scripts/start-local.sh [--build]
set -euo pipefail
cd "$(dirname "$0")/.."

DO_BUILD=false
for arg in "$@"; do
    case "$arg" in
        --build) DO_BUILD=true ;;
        -h|--help)
            echo "Usage: $0 [--build]"
            echo "  --build  Force rebuild of Go server before starting"
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

# Check MediaMTX binary
if [[ ! -x bin/mediamtx ]]; then
    echo "!!! MediaMTX not found, run 'make bin/mediamtx' first."
    exit 1
fi

# Get Tailscale IP
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)
if [[ -z "$TAILSCALE_IP" ]]; then
    echo "!!! Tailscale not running. Start Tailscale first."
    exit 1
fi

# Start MediaMTX with local config
echo "==> Starting MediaMTX (local config)..."
./bin/mediamtx mediamtx-local.yml &
PIDS+=($!)
sleep 2

# Verify MediaMTX is up
if ! curl -sf http://localhost:9997/v3/paths/list > /dev/null 2>&1; then
    echo "!!! MediaMTX failed to start. Check mediamtx-local.yml"
    exit 1
fi
echo "    MediaMTX ready (RTSP :8554, RTMP :1935, HLS :8888, API :9997)"

# SSH reverse tunnel: rpicam3's localhost:1935 → Mac's localhost:1935
echo "==> Starting SSH reverse tunnel to rpicam3..."
ssh -R 1935:localhost:1935 -N -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes rpicam3 &
PIDS+=($!)
sleep 2
echo "    rpicam3 tunnel: Pi localhost:1935 → Mac localhost:1935"

# Update rpicam3 to push to localhost (through the tunnel) and restart
echo "==> Configuring rpicam3 stream..."
ssh -o ConnectTimeout=10 rpicam3 "sudo sed -i 's/MEDIAMTX_HOST=.*/MEDIAMTX_HOST=localhost/' /etc/rpicam-stream.conf && sudo systemctl restart rpicam-stream" &
sleep 3
echo "    rpicam3 streaming via SSH tunnel"

# Start Go server
echo "==> Starting Go server on :8080..."
echo ""
echo "    UI:     http://localhost:8080"
echo "    API:    http://localhost:8080/api/status"
echo "    WebRTC: http://localhost:8889"
echo ""
echo "Press Ctrl+C to stop all services."
echo "---"
CAMERAS=cam3 exec ./bin/server
