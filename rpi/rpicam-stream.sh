#!/bin/bash

# RPiCam Camera Stream Script
# Streams the Pi camera to a MediaMTX server via RTMP
# Designed to run as a systemd service on boot
#
# The RTMP server is reached via an SSH reverse tunnel (see mediamtx-tunnel.service)
# so the target is always 127.0.0.1:1935.

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# --- Configuration (override with env vars or /etc/rpicam-stream.conf) ---
[ -f /etc/rpicam-stream.conf ] && . /etc/rpicam-stream.conf

RTMP_HOST="${MEDIAMTX_HOST:-192.168.50.208}"
RTMP_PORT="${MEDIAMTX_RTMP_PORT:-1935}"
RETRY_DELAY="${RETRY_DELAY:-5}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-30}"
AUDIO_DEVICE="${AUDIO_DEVICE:-hw:2,0}"

# Stream name: rpicamN → camN, or use hostname as-is
detect_stream_name() {
    local name
    name=$(hostname 2>/dev/null | sed 's/\.local$//')
    if [[ "$name" =~ ^rpicam(.+)$ ]]; then
        echo "cam${BASH_REMATCH[1]}"
    else
        echo "$name"
    fi
}
STREAM_NAME="${STREAM_NAME:-$(detect_stream_name)}"

# --- Main ---
log "Camera stream service starting"
log "  Stream: $STREAM_NAME → rtmp://$RTMP_HOST:$RTMP_PORT/$STREAM_NAME"
log "  Resolution: ${WIDTH}x${HEIGHT}@${FPS}fps"
log "  Audio device: ${AUDIO_DEVICE:-none}"

# Wait for camera hardware
wait_for_camera() {
    local attempts=0
    while ! rpicam-vid --list-cameras 2>&1 | grep -q "Available cameras"; do
        attempts=$((attempts + 1))
        if [ $attempts -ge 60 ]; then
            log "ERROR: No camera detected after 60 attempts"
            return 1
        fi
        log "Waiting for camera... (attempt $attempts)"
        sleep 2
    done
    log "Camera detected"
}

# Wait for RTMP port (tunnel must be up first)
wait_for_server() {
    while ! timeout 3 bash -c "</dev/tcp/$RTMP_HOST/$RTMP_PORT" 2>/dev/null; do
        log "Waiting for RTMP tunnel at $RTMP_HOST:$RTMP_PORT..."
        sleep "$RETRY_DELAY"
    done
    log "RTMP server reachable"
}

# Stream loop with auto-retry
retry_count=0
while true; do
    wait_for_camera
    wait_for_server

    retry_count=$((retry_count + 1))
    rtmp_url="rtmp://$RTMP_HOST:$RTMP_PORT/$STREAM_NAME"
    log "Starting stream (attempt $retry_count) → $rtmp_url"

    # Check if audio device is available
    has_audio=false
    if [ -n "$AUDIO_DEVICE" ] && arecord -D "$AUDIO_DEVICE" --dump-hw-params -d 0 2>&1 | grep -q "CHANNELS"; then
        has_audio=true
        log "Audio device $AUDIO_DEVICE available — streaming with audio"
    else
        log "No audio device — streaming video only"
    fi

    if $has_audio; then
        # Use rpicam-vid for video encoding to a FIFO, ffmpeg muxes video + ALSA audio
        fifo="/tmp/rpicam-video-fifo"
        rm -f "$fifo"
        mkfifo "$fifo"

        # rpicam-vid writes FLV video to the FIFO (background)
        rpicam-vid -t 0 --camera 0 --nopreview \
            --width "$WIDTH" --height "$HEIGHT" --framerate "$FPS" \
            --codec libav --libav-format flv \
            --libav-video-codec libx264 \
            --libav-video-codec-opts "preset=ultrafast;tune=zerolatency;g=${FPS};keyint_min=${FPS};bf=0" \
            -o "$fifo" &
        rpicam_pid=$!

        # ffmpeg reads video from FIFO + captures ALSA audio → RTMP
        ffmpeg -fflags +genpts \
            -i "$fifo" \
            -f alsa -channels 1 -sample_rate 48000 -i "$AUDIO_DEVICE" \
            -map 0:v -map 1:a \
            -c:v copy \
            -c:a aac -b:a 128k \
            -f flv \
            -flvflags no_duration_filesize \
            "$rtmp_url" || true

        kill "$rpicam_pid" 2>/dev/null; wait "$rpicam_pid" 2>/dev/null
        rm -f "$fifo"
    else
        # Video-only fallback (original behavior)
        rpicam-vid -t 0 --camera 0 --nopreview \
            --width "$WIDTH" --height "$HEIGHT" --framerate "$FPS" \
            --codec libav --libav-format flv \
            --libav-video-codec libx264 \
            --libav-video-codec-opts "preset=ultrafast;tune=zerolatency;g=30;keyint_min=30;bf=0" \
            -o "$rtmp_url" || true
    fi

    log "Stream exited (attempt $retry_count). Retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
done