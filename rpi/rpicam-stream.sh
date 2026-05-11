#!/bin/bash

# RPiCam Camera Stream Script
# Streams the Pi camera to a MediaMTX server via SRT (low-latency UDP)
# Falls back to RTMP if SRT is unavailable
# Designed to run as a systemd service on boot
#
# Hardware encoding (rpicam-vid GPU H264) is auto-enabled on Pi Zero 2W
# where x264 software encode is too heavy. Pi 5 uses x264 (plenty of CPU).

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# --- Configuration (override with env vars or /etc/rpicam-stream.conf) ---
[ -f /etc/rpicam-stream.conf ] && . /etc/rpicam-stream.conf

MEDIAMTX_HOST="${MEDIAMTX_HOST:-192.168.50.208}"
SRT_PORT="${SRT_PORT:-8890}"
RTMP_PORT="${MEDIAMTX_RTMP_PORT:-1935}"
RTSP_PORT="${RTSP_PORT:-8554}"
# NOTE: Use RTSP for WebRTC/WHEP audio (Opus). RTMP uses AAC which WebRTC can't play.
# SRT (UDP) causes corrupted frames over WiFi. RTSP and RTMP are both TCP (reliable).
PROTOCOL="${PROTOCOL:-rtsp}"
RETRY_DELAY="${RETRY_DELAY:-5}"
WIDTH="${WIDTH:-1920}"
HEIGHT="${HEIGHT:-1080}"
FPS="${FPS:-30}"
AUDIO_DEVICE="${AUDIO_DEVICE:-hw:2,0}"
BITRATE="${BITRATE:-5500}"
SPEED_PRESET="${SPEED_PRESET:-medium}"  # x264 speed preset: ultrafast, superfast, veryfast, faster, fast, medium
SRT_LATENCY="${SRT_LATENCY:-200}"  # SRT latency in ms (lower = less latency, more risk)
HW_ENCODE="${HW_ENCODE:-auto}"     # auto, yes, or no — use rpicam-vid hardware H264 encoder

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

# Detect Pi model once at startup
PI_MODEL=$(cat /proc/device-tree/model 2>/dev/null || echo "")
IS_ZERO_2W=false
[[ "$PI_MODEL" == *"Zero 2"* ]] && IS_ZERO_2W=true

# Pi Zero 2W: camera driver needs extra time to initialize on boot.
# Without this delay, rpicam-vid starts before unicam is ready, causing
# "Failed to start media pipeline: -22" spam and a wedged SRT connection.
# Also, rpicam-vid --list-cameras is unreliable on Zero 2W (reports
# "No cameras available" even when the camera works fine).
if $IS_ZERO_2W; then
    log "Pi Zero 2W detected — waiting 10s for camera drivers to load"
    sleep 10
fi

# --- Main ---
log "Camera stream service starting"
log "  Model: $PI_MODEL"
log "  Protocol: $PROTOCOL"
log "  Stream: $STREAM_NAME → ${MEDIAMTX_HOST}"
log "  Resolution: ${WIDTH}x${HEIGHT}@${FPS}fps @ ${BITRATE}kbps"
log "  Audio device: ${AUDIO_DEVICE:-none}"

# Wait for camera hardware
# On Pi Zero 2W, rpicam-vid --list-cameras is unreliable (the camera is
# locked by the unicam driver during init and reports "No cameras available"
# even when it works). So on Zero 2W we skip this check and rely on the
# boot delay + pipeline retry loop instead.
wait_for_camera() {
    if $IS_ZERO_2W; then
        log "Pi Zero 2W — skipping camera detection (unreliable), relying on boot delay"
        return 0
    fi
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
    elif [ "$PROTOCOL" = "rtsp" ]; then
        while ! timeout 3 bash -c "</dev/tcp/$MEDIAMTX_HOST/$RTSP_PORT" 2>/dev/null; do
            log "Waiting for RTSP at $MEDIAMTX_HOST:$RTSP_PORT..."
            sleep "$RETRY_DELAY"
        done
        log "RTSP server reachable"
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
            # For RTMP/RTSP (TCP): check for CLOSE-WAIT (server disconnected)
            local watch_port="$RTMP_PORT"
            [ "$PROTOCOL" = "rtsp" ] && watch_port="$RTSP_PORT"
            local close_wait
            close_wait=$(ss -tnp 2>/dev/null | grep ":${watch_port}" | grep -c "CLOSE-WAIT" || true)
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
            send_q=$(ss -tnp 2>/dev/null | grep ":${watch_port}" | grep -v "FIN\|CLOSE\|TIME" | awk '{print $3}' | sort -rn | head -1)
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

while true; do
    wait_for_camera
    wait_for_server

    retry_count=$((retry_count + 1))
    log "Starting stream (attempt $retry_count) via $PROTOCOL"

    # Determine if hardware encoding should be used
    # Auto mode: only on Pi Zero 2W (too weak for x264 software encode)
    # RPi 5 has plenty of CPU for x264 — no hw encoder on BCM2712 anyway
    use_hw=false
    if [ "$HW_ENCODE" = "yes" ]; then
        use_hw=true
    elif [ "$HW_ENCODE" = "auto" ]; then
        if $IS_ZERO_2W && gst-inspect-1.0 v4l2h264enc >/dev/null 2>&1; then
            use_hw=true
            log "Pi Zero 2W detected — using v4l2h264enc hardware H264 encoder"
        fi
    fi

    # Check if audio device is available
    has_audio=false
    if [ -n "$AUDIO_DEVICE" ] && arecord -D "$AUDIO_DEVICE" --dump-hw-params -d 0 2>&1 | grep -q "CHANNELS"; then
        has_audio=true
        log "Audio device $AUDIO_DEVICE available — streaming with audio"
    else
        log "No audio device — streaming video only"
    fi

    if $use_hw; then
        # Hardware encode: v4l2h264enc uses the VideoCore GPU H264 encoder
        # via V4L2 M2M — all within GStreamer for proper timestamps & muxing.
        # repeat_sequence_header=1 = inline SPS/PPS (needed for mid-stream joins)
        # h264_profile: 0=Baseline, 2=Main, 4=High
        V4L2_CONTROLS="controls,video_bitrate=$((BITRATE * 1000)),repeat_sequence_header=1,h264_profile=4"
        if $has_audio; then
            if [ "$PROTOCOL" = "srt" ]; then
                gst-launch-1.0 -e \
                    libcamerasrc ! "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1,format=NV12" ! \
                    v4l2h264enc extra-controls="$V4L2_CONTROLS" ! "video/x-h264,level=(string)4" ! \
                    h264parse ! queue max-size-buffers=1 leaky=downstream ! \
                    mpegtsmux name=mux alignment=7 ! \
                    queue max-size-bytes=2000000 max-size-time=0 max-size-buffers=0 ! \
                    srtsink uri="srt://${MEDIAMTX_HOST}:${SRT_PORT}?streamid=publish:${STREAM_NAME}&pkt_size=1316" latency=${SRT_LATENCY} \
                    alsasrc device="$AUDIO_DEVICE" buffer-time=200000 ! "audio/x-raw,rate=48000,channels=1" ! \
                    queue max-size-buffers=1 max-size-time=500000000 leaky=downstream ! \
                    audioconvert ! opusenc bitrate=128000 frame-size=20 ! opusparse ! mux. \
                    2>&1 &
            else
                gst-launch-1.0 -e \
                    libcamerasrc ! "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1,format=NV12" ! \
                    v4l2h264enc extra-controls="$V4L2_CONTROLS" ! "video/x-h264,level=(string)4" ! \
                    h264parse ! queue max-size-buffers=1 leaky=downstream ! \
                    flvmux name=mux streamable=true ! \
                    rtmpsink location="rtmp://${MEDIAMTX_HOST}:${RTMP_PORT}/${STREAM_NAME}" \
                    alsasrc device="$AUDIO_DEVICE" buffer-time=200000 ! "audio/x-raw,rate=48000,channels=1" ! \
                    queue max-size-buffers=1 max-size-time=500000000 leaky=downstream ! \
                    audioconvert ! avenc_aac ! aacparse ! mux. \
                    2>&1 &
            fi
        else
            if [ "$PROTOCOL" = "srt" ]; then
                gst-launch-1.0 -e \
                    libcamerasrc ! "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1,format=NV12" ! \
                    v4l2h264enc extra-controls="$V4L2_CONTROLS" ! "video/x-h264,level=(string)4" ! \
                    h264parse ! queue max-size-buffers=1 leaky=downstream ! mpegtsmux alignment=7 ! \
                    queue max-size-bytes=2000000 max-size-time=0 max-size-buffers=0 ! \
                    srtsink uri="srt://${MEDIAMTX_HOST}:${SRT_PORT}?streamid=publish:${STREAM_NAME}&pkt_size=1316" latency=${SRT_LATENCY} \
                    2>&1 &
            else
                gst-launch-1.0 -e \
                    libcamerasrc ! "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1,format=NV12" ! \
                    v4l2h264enc extra-controls="$V4L2_CONTROLS" ! "video/x-h264,level=(string)4" ! \
                    h264parse ! queue max-size-buffers=1 leaky=downstream ! flvmux streamable=true ! \
                    rtmpsink location="rtmp://${MEDIAMTX_HOST}:${RTMP_PORT}/${STREAM_NAME}" \
                    2>&1 &
            fi
        fi
    elif $has_audio; then
        if [ "$PROTOCOL" = "srt" ]; then
            # SRT with audio: MPEG-TS mux with Opus audio
            # Opus is used because WebRTC (the browser viewer) only supports Opus, not AAC.
            # mpegtsmux latency=3s ensures it waits for data on ALL pads before
            # writing the first PMT. Without this, audio arrives before x264enc
            # produces its first frame, so the PMT only lists audio and MediaMTX
            # (which only reads the first PMT) misses the video track entirely.
            gst-launch-1.0 -e \
                libcamerasrc ! "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1,format=NV12" ! \
                queue max-size-buffers=1 leaky=downstream ! \
                videoconvert ! x264enc tune=zerolatency speed-preset=${SPEED_PRESET} bitrate=${BITRATE} key-int-max=60 threads=4 ! \
                h264parse ! mpegtsmux name=mux latency=3000000000 ! \
                srtsink uri="srt://${MEDIAMTX_HOST}:${SRT_PORT}?streamid=publish:${STREAM_NAME}&pkt_size=1316" latency=${SRT_LATENCY} \
                alsasrc device="$AUDIO_DEVICE" buffer-time=200000 ! "audio/x-raw,rate=48000,channels=1" ! \
                queue max-size-buffers=1 max-size-time=500000000 leaky=downstream ! \
                audioconvert ! opusenc bitrate=128000 frame-size=20 ! opusparse ! mux. \
                2>&1 &
        elif [ "$PROTOCOL" = "rtsp" ]; then
            # RTSP with audio: rtspclientsink with Opus audio
            # Opus is native to WebRTC/WHEP — no server-side transcoding needed.
            # RTSP uses TCP (like RTMP) so it's reliable over WiFi.
            gst-launch-1.0 -e \
                libcamerasrc ! "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1,format=NV12" ! \
                queue max-size-buffers=1 leaky=downstream ! \
                videoconvert ! x264enc tune=zerolatency speed-preset=${SPEED_PRESET} bitrate=${BITRATE} key-int-max=60 threads=4 ! \
                h264parse ! rtspclientsink name=mux location="rtsp://${MEDIAMTX_HOST}:${RTSP_PORT}/${STREAM_NAME}" protocols=tcp latency=0 \
                alsasrc device="$AUDIO_DEVICE" buffer-time=200000 ! "audio/x-raw,rate=48000,channels=1" ! \
                queue max-size-buffers=1 max-size-time=500000000 leaky=downstream ! \
                audioconvert ! opusenc bitrate=128000 frame-size=20 ! opusparse ! mux. \
                2>&1 &
        else
            # RTMP with audio (AAC — works for HLS but NOT for WebRTC/WHEP)
            gst-launch-1.0 -e \
                libcamerasrc ! "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1,format=NV12" ! \
                queue max-size-buffers=1 leaky=downstream ! \
                videoconvert ! x264enc tune=zerolatency speed-preset=${SPEED_PRESET} bitrate=${BITRATE} key-int-max=60 threads=4 ! \
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
                videoconvert ! x264enc tune=zerolatency speed-preset=${SPEED_PRESET} bitrate=${BITRATE} key-int-max=60 threads=4 ! \
                h264parse ! mpegtsmux ! \
                srtsink uri="srt://${MEDIAMTX_HOST}:${SRT_PORT}?streamid=publish:${STREAM_NAME}&pkt_size=1316" latency=${SRT_LATENCY} \
                2>&1 &
        elif [ "$PROTOCOL" = "rtsp" ]; then
            # RTSP video-only
            gst-launch-1.0 -e \
                libcamerasrc ! "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1,format=NV12" ! \
                queue max-size-buffers=1 leaky=downstream ! \
                videoconvert ! x264enc tune=zerolatency speed-preset=${SPEED_PRESET} bitrate=${BITRATE} key-int-max=60 threads=4 ! \
                h264parse ! rtspclientsink location="rtsp://${MEDIAMTX_HOST}:${RTSP_PORT}/${STREAM_NAME}" protocols=tcp latency=0 \
                2>&1 &
        else
            # RTMP video-only
            gst-launch-1.0 -e \
                libcamerasrc ! "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1,format=NV12" ! \
                queue max-size-buffers=1 leaky=downstream ! \
                videoconvert ! x264enc tune=zerolatency speed-preset=${SPEED_PRESET} bitrate=${BITRATE} key-int-max=60 threads=4 ! \
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