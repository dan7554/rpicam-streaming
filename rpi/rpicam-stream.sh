#!/bin/bash

# RPiCam Camera Stream Script
# Streams the Pi camera to a MediaMTX server via RTMP
# Designed to run as a systemd service on boot
#
# The RTMP server is reached via Tailscale (set MEDIAMTX_HOST to the
# Tailscale IP of the Mac running MediaMTX).
# Requires: tailscale serve --bg --tcp 1935 tcp://localhost:1935 on the Mac.

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
GOP="${GOP:-8}"
AUDIO_DEVICE="${AUDIO_DEVICE:-hw:2,0}"
BITRATE="${BITRATE:-3000}"

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
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-10}"
WATCHDOG_THRESHOLD="${WATCHDOG_THRESHOLD:-500000}"  # 500KB send buffer = stuck
WATCHDOG_MAX_STRIKES="${WATCHDOG_MAX_STRIKES:-3}"   # 3 consecutive checks = kill

# Watchdog: monitors RTMP send buffer, kills GStreamer if stuck
start_watchdog() {
    local gst_pid="$1"
    local strikes=0
    while kill -0 "$gst_pid" 2>/dev/null; do
        sleep "$WATCHDOG_INTERVAL"
        # Get send-Q for connections to RTMP port
        local send_q
        send_q=$(ss -tnp 2>/dev/null | grep ":${RTMP_PORT}" | grep -v "FIN\|CLOSE\|TIME" | awk '{print $3}' | sort -rn | head -1)
        send_q="${send_q:-0}"

        if [ "$send_q" -gt "$WATCHDOG_THRESHOLD" ]; then
            strikes=$((strikes + 1))
            log "WATCHDOG: send buffer ${send_q} bytes (strike $strikes/$WATCHDOG_MAX_STRIKES)"
            if [ "$strikes" -ge "$WATCHDOG_MAX_STRIKES" ]; then
                log "WATCHDOG: connection stuck, killing GStreamer (pid $gst_pid)"
                kill "$gst_pid" 2>/dev/null
                sleep 1
                kill -9 "$gst_pid" 2>/dev/null
                return
            fi
        else
            strikes=0
        fi
    done
}

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
        # Single GStreamer pipeline: shared clock keeps A/V in sync.
        # libcamerasrc + alsasrc → flvmux → rtmpsink
        gst-launch-1.0 -e \
            libcamerasrc ! "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1,format=NV12" ! queue ! \
            videoconvert ! x264enc tune=zerolatency speed-preset=ultrafast bitrate=${BITRATE} key-int-max="${GOP}" bframes=0 threads=4 ! \
            h264parse ! flvmux name=mux streamable=true ! \
            rtmpsink location="$rtmp_url" \
            alsasrc device="$AUDIO_DEVICE" buffer-time=200000 ! "audio/x-raw,rate=48000,channels=1" ! queue max-size-time=3000000000 ! \
            audioconvert ! avenc_aac ! aacparse ! mux. \
            2>&1 &
    else
        # Video-only GStreamer pipeline
        gst-launch-1.0 -e \
            libcamerasrc ! "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1,format=NV12" ! queue ! \
            videoconvert ! x264enc tune=zerolatency speed-preset=ultrafast bitrate=${BITRATE} key-int-max="${GOP}" bframes=0 threads=4 ! \
            h264parse ! flvmux streamable=true ! \
            rtmpsink location="$rtmp_url" \
            2>&1 &
    fi

    GST_PID=$!
    log "GStreamer started (pid $GST_PID), watchdog monitoring send buffer"
    start_watchdog "$GST_PID" &
    WATCHDOG_PID=$!
    wait "$GST_PID" 2>/dev/null
    kill "$WATCHDOG_PID" 2>/dev/null
    wait "$WATCHDOG_PID" 2>/dev/null

    log "Stream exited (attempt $retry_count). Retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
done