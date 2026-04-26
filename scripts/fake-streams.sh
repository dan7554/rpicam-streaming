#!/usr/bin/env bash
# Launch 2 fake FFmpeg streams into MediaMTX via RTSP
# cam3 is a real RPi camera (rpicam3) pushing RTSP to this server
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

echo "Starting fake streams → rtsp://${RTSP_HOST}:${RTSP_PORT}/cam{1,2}"
echo "(cam3 = rpicam3 via Tailscale)"

# cam1: SMPTE color bars
ffmpeg -re -f lavfi \
    -i "smptebars=size=1280x720:rate=30" \
    -f lavfi -i "sine=frequency=400:sample_rate=48000" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 2M \
    -c:a aac -b:a 128k \
    -f rtsp "rtsp://${RTSP_HOST}:${RTSP_PORT}/cam1" &
PIDS+=($!)

# cam2: Mandelbrot fractal zoom
ffmpeg -re -f lavfi \
    -i "mandelbrot=size=1280x720:rate=30" \
    -f lavfi -i "sine=frequency=600:sample_rate=48000" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 2M \
    -c:a aac -b:a 128k \
    -f rtsp "rtsp://${RTSP_HOST}:${RTSP_PORT}/cam2" &
PIDS+=($!)

echo "Fake streams running (PIDs: ${PIDS[*]}). Press Ctrl+C to stop."
wait
