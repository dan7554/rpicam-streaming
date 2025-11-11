#!/bin/bash

# RPiCam RTSP Stream Script with Retry Logic
# This script runs the rpicam-vid command with automatic retry on failure

# Configuration
# RTSP_SERVER="rtsp.racetrackstreaming.com:8554"  # RTSP endpoint with A record to ECS IP
RTSP_SERVER="192.168.50.208:8554"
STREAM_NAME="rpicam3"
MAX_RETRIES=0  # 0 means infinite retries
RETRY_DELAY=5  # seconds between retries
CONNECTION_TIMEOUT=30  # seconds to wait for RTSP server

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to check if RTSP server is reachable
check_rtsp_server() {
    # Extract hostname and port from RTSP_SERVER
    IFS=':' read -r hostname port <<< "$RTSP_SERVER"
    if [ -z "$port" ]; then
        port=8554  # default RTSP port
    fi
    
    # Test connection to RTSP server
    timeout $CONNECTION_TIMEOUT bash -c "</dev/tcp/$hostname/$port" 2>/dev/null
    return $?
}

# Function to run the streaming command
run_stream() {
    log "Starting RPiCam stream to rtsp://$RTSP_SERVER/$STREAM_NAME"
    

#                                      number
#   --brightness arg (=0)                 Adjust the brightness of the output images, in the range -1.0 to 1.0
#   --contrast arg (=1)                   Adjust the contrast of the output image, where 1.0 = normal contrast
#   --saturation arg (=1)                 Adjust the colour saturation of the output, where 1.0 = normal and 0.0 = 
#                                         greyscale
#   --sharpness arg (=1)                  Adjust the sharpness of the output image, where 1.0 = normal sharpening
#   --framerate arg (=-1)                 Set the fixed framerate for preview and video modes

    # Your streaming command here
    rpicam-vid -t 0 --camera 0 --nopreview --codec yuv420 --brightness 0 --contrast 1 --saturation 1 --width 1280 --height 720 --framerate 30 --inline -o - | \
    ffmpeg -f rawvideo -pix_fmt yuv420p -s:v 1280x720 -r 30 -i - -c:v libx264 -preset veryfast -tune zerolatency -f rtsp -rtsp_transport tcp rtsp://$RTSP_SERVER/$STREAM_NAME
}

# Main loop with retry logic
retry_count=0

while true; do
    # Check if we've exceeded max retries (if set)
    if [ $MAX_RETRIES -gt 0 ] && [ $retry_count -ge $MAX_RETRIES ]; then
        log "Maximum retry attempts ($MAX_RETRIES) reached. Exiting."
        exit 1
    fi
    
    # Wait for RTSP server to be available
    log "Checking RTSP server availability..."
    while ! check_rtsp_server; do
        log "RTSP server at $RTSP_SERVER not reachable. Waiting $RETRY_DELAY seconds..."
        sleep $RETRY_DELAY
    done
    
    log "RTSP server is reachable. Starting stream (attempt $((retry_count + 1)))"
    
    # Run the streaming command
    run_stream
    
    # If we reach here, the command failed
    exit_code=$?
    retry_count=$((retry_count + 1))
    
    log "Stream failed with exit code $exit_code. Retrying in $RETRY_DELAY seconds..."
    sleep $RETRY_DELAY
done