#!/usr/bin/env bash
# Launch cam1 fake FFmpeg stream into MediaMTX via RTSP
# cam2 = rpicam2, cam3 = rpicam3 (real RPi cameras pushing RTMP)
set -e

RTSP_HOST="${RTSP_HOST:-localhost}"
RTSP_PORT="${RTSP_PORT:-8554}"
PIDS=()

cleanup() {
    echo "Stopping fake streams..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    exit 0
}
trap cleanup SIGINT SIGTERM

echo "Starting fake stream → rtsp://${RTSP_HOST}:${RTSP_PORT}/cam1"
echo "(cam2 = rpicam2, cam3 = rpicam3 via Tailscale/RTMP)"

# cam1: SMPTE color bars (fake test stream)
ffmpeg -re -f lavfi \
    -i "smptebars=size=1280x720:rate=30" \
    -f lavfi -i "sine=frequency=400:sample_rate=48000" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 2M \
    -c:a aac -b:a 128k \
    -f rtsp "rtsp://${RTSP_HOST}:${RTSP_PORT}/cam1" &
PIDS+=($!)

echo "Fake stream running (PID: ${PIDS[*]}). Press Ctrl+C to stop."
echo "Waiting for rpicam2 → cam2 and rpicam3 → cam3 to push RTMP..."
wait
