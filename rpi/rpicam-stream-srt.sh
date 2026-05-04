#!/bin/bash

# RPiCam Camera Stream Script
# Streams the Pi camera to a MediaMTX server via SRT (low-latency UDP)
# Falls back to RTMP if SRT is unavailable
# Designed to run as a systemd service on boot

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# --- Configuration (override with env vars or /etc/rpicam-stream.conf) ---
[ -f /etc/rpicam-stream.conf ] && . /etc/rpicam-stream.conf

MEDIAMTX_HOST="${MEDIAMTX_HOST:-192.168.50.208}"
SRT_PORT="${SRT_PORT:-8890}"
RTMP_PORT="${MEDIAMTX_RTMP_PORT:-1935}"
PROTOCOL="${PROTOCOL:-srt}"  # srt or rtmp
RETRY_DELAY="${RETRY_DELAY:-5}"
WIDTH="${WIDTH:-1920}"
HEIGHT="${HEIGHT:-1080}"
FPS="${FPS:-30}"
AUDIO_DEVICE="${AUDIO_DEVICE:-hw:2,0}"
BITRATE="${BITRATE:-5500}"
SRT_LATENCY="${SRT_LATENCY:-200}"  # SRT latency in ms (lower = less latency, more risk)

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
log "  Protocol: $PROTOCOL"
log "  Stream: $STREAM_NAME → ${MEDIAMTX_HOST}"
log "  Resolution: ${WIDTH}x${HEIGHT}@${FPS}fps @ ${BITRATE}kbps"
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

# Wait for server reachability
wait_for_server() {
    if [ "$PROTOCOL" = "srt" ]; then
        # For SRT (UDP), check host reachability via RTMP TCP port
        # (ping may be blocked by security groups)
        while ! timeout 3 bash -c "</dev/tcp/$MEDIAMTX_HOST/$RTMP_PORT" 2>/dev/null; do
            log "Waiting for host $MEDIAMTX_HOST (checking port $RTMP_PORT)..."
            sleep "$RETRY_DELAY"
        done
        log "Host $MEDIAMTX_HOST reachable (SRT/UDP)"
    else
        # For RTMP (TCP), check port
        while ! timeout 3 bash -c "</dev/tcp/$MEDIAMTX_HOST/$RTMP_PORT" 2>/dev/null; do
            log "Waiting for RTMP at $MEDIAMTX_HOST:$RTMP_PORT..."
            sleep "$RETRY_DELAY"
        done
        log "RTMP server reachable"
    fi
}

# Stream loop with auto-retry
retry_count=0
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-10}"
WATCHDOG_THRESHOLD="${WATCHDOG_THRESHOLD:-500000}"  # 500KB send buffer = stuck
WATCHDOG_MAX_STRIKES="${WATCHDOG_MAX_STRIKES:-3}"   # 3 consecutive checks = kill

# Watchdog: monitors connection health, kills GStreamer if stuck
start_watchdog() {
    local gst_pid="$1"
    local strikes=0
    local closewait_strikes=0
    local no_conn_strikes=0
    while kill -0 "$gst_pid" 2>/dev/null; do
        sleep "$WATCHDOG_INTERVAL"

        if [ "$PROTOCOL" = "srt" ]; then
            # For SRT: check if the process is still running and producing output
            # SRT is UDP so no TCP state to check — monitor process CPU instead
            local cpu
            cpu=$(ps -o %cpu= -p "$gst_pid" 2>/dev/null | tr -d ' ')
            cpu="${cpu:-0}"
            # If CPU drops to near 0 for multiple checks, pipeline is stalled
            if [ "$(echo "$cpu < 1" | bc 2>/dev/null || echo 0)" = "1" ]; then
                no_conn_strikes=$((no_conn_strikes + 1))
                log "WATCHDOG: SRT pipeline CPU ${cpu}% (strike $no_conn_strikes/3)"
                if [ "$no_conn_strikes" -ge 3 ]; then
                    log "WATCHDOG: SRT pipeline stalled, killing GStreamer (pid $gst_pid)"
                    kill "$gst_pid" 2>/dev/null
                    sleep 1
                    kill -9 "$gst_pid" 2>/dev/null
                    return
                fi
            else
                no_conn_strikes=0
            fi
        else
            # For RTMP: check for CLOSE-WAIT (server disconnected)
            local close_wait
            close_wait=$(ss -tnp 2>/dev/null | grep ":${RTMP_PORT}" | grep -c "CLOSE-WAIT" || true)
            if [ "${close_wait:-0}" -gt 0 ]; then
                closewait_strikes=$((closewait_strikes + 1))
                log "WATCHDOG: CLOSE-WAIT detected (strike $closewait_strikes/2)"
                if [ "$closewait_strikes" -ge 2 ]; then
                    log "WATCHDOG: server gone (CLOSE-WAIT), killing GStreamer (pid $gst_pid)"
                    kill "$gst_pid" 2>/dev/null
                    sleep 1
                    kill -9 "$gst_pid" 2>/dev/null
                    return
                fi
            else
                closewait_strikes=0
            fi

            # Check for stuck send buffer
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
        fi
    done
}

# Build the GStreamer sink based on protocol
build_sink() {
    if [ "$PROTOCOL" = "srt" ]; then
        # SRT caller mode: push MPEG-TS over SRT to MediaMTX
        # streamid tells MediaMTX which path to publish to
        echo "mpegtsmux ! srtsink uri=\"srt://${MEDIAMTX_HOST}:${SRT_PORT}?streamid=publish:${STREAM_NAME}&pkt_size=1316\" latency=${SRT_LATENCY}"
    else
        # RTMP: push FLV over RTMP
        echo "flvmux streamable=true ! rtmpsink location=\"rtmp://${MEDIAMTX_HOST}:${RTMP_PORT}/${STREAM_NAME}\""
    fi
}

while true; do
    wait_for_camera
    wait_for_server

    retry_count=$((retry_count + 1))
    log "Starting stream (attempt $retry_count) via $PROTOCOL"

    # Check if audio device is available
    has_audio=false
    if [ -n "$AUDIO_DEVICE" ] && arecord -D "$AUDIO_DEVICE" --dump-hw-params -d 0 2>&1 | grep -q "CHANNELS"; then
        has_audio=true
        log "Audio device $AUDIO_DEVICE available — streaming with audio"
    else
        log "No audio device — streaming video only"
    fi

    SINK=$(build_sink)

    if $has_audio; then
        if [ "$PROTOCOL" = "srt" ]; then
            # SRT with audio: MPEG-TS mux
            gst-launch-1.0 -e \
                libcamerasrc ! "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1,format=NV12" ! \
                queue max-size-buffers=1 leaky=downstream ! \
                videoconvert ! x264enc tune=zerolatency speed-preset=faster bitrate=${BITRATE} key-int-max=30 bframes=0 threads=4 ! \
                h264parse ! mpegtsmux name=mux ! \
                srtsink uri="srt://${MEDIAMTX_HOST}:${SRT_PORT}?streamid=publish:${STREAM_NAME}&pkt_size=1316" latency=${SRT_LATENCY} \
                alsasrc device="$AUDIO_DEVICE" buffer-time=200000 ! "audio/x-raw,rate=48000,channels=1" ! \
                queue max-size-buffers=1 max-size-time=500000000 leaky=downstream ! \
                audioconvert ! avenc_aac ! aacparse ! mux. \
                2>&1 &
        else
            # RTMP with audio
            gst-launch-1.0 -e \
                libcamerasrc ! "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1,format=NV12" ! \
                queue max-size-buffers=1 leaky=downstream ! \
                videoconvert ! x264enc tune=zerolatency speed-preset=faster bitrate=${BITRATE} key-int-max=30 bframes=0 threads=4 ! \
                h264parse ! flvmux name=mux streamable=true ! \
                rtmpsink location="rtmp://${MEDIAMTX_HOST}:${RTMP_PORT}/${STREAM_NAME}" \
                alsasrc device="$AUDIO_DEVICE" buffer-time=200000 ! "audio/x-raw,rate=48000,channels=1" ! \
                queue max-size-buffers=1 max-size-time=500000000 leaky=downstream ! \
                audioconvert ! avenc_aac ! aacparse ! mux. \
                2>&1 &
        fi
    else
        if [ "$PROTOCOL" = "srt" ]; then
            # SRT video-only
            gst-launch-1.0 -e \
                libcamerasrc ! "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1,format=NV12" ! \
                queue max-size-buffers=1 leaky=downstream ! \
                videoconvert ! x264enc tune=zerolatency speed-preset=faster bitrate=${BITRATE} key-int-max=30 bframes=0 threads=4 ! \
                h264parse ! mpegtsmux ! \
                srtsink uri="srt://${MEDIAMTX_HOST}:${SRT_PORT}?streamid=publish:${STREAM_NAME}&pkt_size=1316" latency=${SRT_LATENCY} \
                2>&1 &
        else
            # RTMP video-only
            gst-launch-1.0 -e \
                libcamerasrc ! "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1,format=NV12" ! \
                queue max-size-buffers=1 leaky=downstream ! \
                videoconvert ! x264enc tune=zerolatency speed-preset=faster bitrate=${BITRATE} key-int-max=30 bframes=0 threads=4 ! \
                h264parse ! flvmux streamable=true ! \
                rtmpsink location="rtmp://${MEDIAMTX_HOST}:${RTMP_PORT}/${STREAM_NAME}" \
                2>&1 &
        fi
    fi

    GST_PID=$!
    log "GStreamer started (pid $GST_PID), watchdog monitoring ($PROTOCOL)"
    start_watchdog "$GST_PID" &
    WATCHDOG_PID=$!
    wait "$GST_PID" 2>/dev/null
    kill "$WATCHDOG_PID" 2>/dev/null
    wait "$WATCHDOG_PID" 2>/dev/null

    log "Stream exited (attempt $retry_count). Retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
done
