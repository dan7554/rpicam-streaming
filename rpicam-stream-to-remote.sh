#!/bin/bash

# RPiCam RTSP Stream Script - Stream to Remote MediaMTX Server
# This script streams from Pi camera to a remote MediaMTX instance

# Configuration - Update these to match your setup
MEDIAMTX_SERVER="192.168.50.147"  # IP of your Mac/computer running MediaMTX
MEDIAMTX_PORT="8554"              # RTSP port on MediaMTX server
STREAM_NAME="rpicam"              # Stream path name
MAX_RETRIES=0                     # 0 means infinite retries
RETRY_DELAY=5                     # seconds between retries
CONNECTION_TIMEOUT=10             # seconds to wait for server

# Camera settings
CAMERA_WIDTH=1920
CAMERA_HEIGHT=1080
CAMERA_FPS=30
CAMERA_BITRATE=5000000

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to check if MediaMTX server is reachable
check_mediamtx_server() {
    # Test connection to MediaMTX server
    timeout $CONNECTION_TIMEOUT bash -c "</dev/tcp/$MEDIAMTX_SERVER/$MEDIAMTX_PORT" 2>/dev/null
    return $?
}

# Function to run the streaming command
run_rpicam_stream() {
    log "Starting RPiCam stream to rtsp://$MEDIAMTX_SERVER:$MEDIAMTX_PORT/$STREAM_NAME"
    
    # RPi Camera streaming command
    rpicam-vid -t 0 --camera 0 --nopreview \
        --codec yuv420 \
        --width $CAMERA_WIDTH \
        --height $CAMERA_HEIGHT \
        --framerate $CAMERA_FPS \
        --brightness 0 \
        --contrast 1 \
        --saturation 1 \
        --inline -o - | \
    ffmpeg -f rawvideo -pix_fmt yuv420p \
        -s:v ${CAMERA_WIDTH}x${CAMERA_HEIGHT} \
        -r $CAMERA_FPS -i - \
        -c:v libx264 \
        -preset veryfast \
        -tune zerolatency \
        -b:v $CAMERA_BITRATE \
        -maxrate $CAMERA_BITRATE \
        -bufsize $((CAMERA_BITRATE * 2)) \
        -f rtsp \
        -rtsp_transport tcp \
        rtsp://$MEDIAMTX_SERVER:$MEDIAMTX_PORT/$STREAM_NAME
}

# Main loop with retry logic
retry_count=0

log "RPi Camera Streaming to Remote MediaMTX"
log "Target: rtsp://$MEDIAMTX_SERVER:$MEDIAMTX_PORT/$STREAM_NAME"
log "Camera: ${CAMERA_WIDTH}x${CAMERA_HEIGHT} @ ${CAMERA_FPS}fps"

while true; do
    # Check if we've exceeded max retries (if set)
    if [ $MAX_RETRIES -gt 0 ] && [ $retry_count -ge $MAX_RETRIES ]; then
        log "Maximum retry attempts ($MAX_RETRIES) reached. Exiting."
        exit 1
    fi
    
    # Wait for MediaMTX server to be available
    log "Checking MediaMTX server availability at $MEDIAMTX_SERVER:$MEDIAMTX_PORT..."
    while ! check_mediamtx_server; do
        log "MediaMTX server not reachable. Waiting $RETRY_DELAY seconds..."
        sleep $RETRY_DELAY
    done
    
    log "MediaMTX server is reachable. Starting stream (attempt $((retry_count + 1)))"
    
    # Run the streaming command
    run_rpicam_stream
    
    # If we reach here, the command failed
    exit_code=$?
    retry_count=$((retry_count + 1))
    
    log "Stream failed with exit code $exit_code. Retrying in $RETRY_DELAY seconds..."
    sleep $RETRY_DELAY
done