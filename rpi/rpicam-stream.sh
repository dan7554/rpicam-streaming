#!/bin/bash

# RPiCam RTSP Stream Script with Retry Logic
# This script runs the rpicam-vid command with automatic retry on failure

# Configuration
# NOTE: Use direct IP address to bypass CloudFlare proxy (CloudFlare doesn't support RTMP/RTSP)
# When MediaMTX ECS task is redeployed, update IP using:
# aws ecs describe-tasks --cluster mediamtx-cluster --tasks $(aws ecs list-tasks --cluster mediamtx-cluster --region us-east-2 --query 'taskArns[0]' --output text) --region us-east-2 --query 'tasks[0].attachments[?type==`ElasticNetworkInterface`].details[?name==`primaryPublicIpv4Address`].value' --output text
RTSP_SERVER_DOMAIN="13.59.160.208"  # Direct public IP of MediaMTX ECS task (bypasses CloudFlare proxy)
RTSP_SERVER_PORT="1935"  # RTMP port (not RTSP 8554)
STREAM_NAME="rpicam2"
MAX_RETRIES=0  # 0 means infinite retries
RETRY_DELAY=5  # seconds between retries
CONNECTION_TIMEOUT=30  # seconds to wait for RTSP server
DNS_SERVER="8.8.8.8"  # Google DNS - works on cellular when carrier DNS fails

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to resolve hostname - bypasses cache by always using fresh lookup
resolve_hostname() {
    local hostname=$1
    # Use Python for fresh DNS resolution
    local ip=$(python3 -c "import socket; print(socket.gethostbyname('$hostname'))" 2>/dev/null)
    # If python3 fails, try getent
    if [ -z "$ip" ] || [ "$ip" = "127.0.0.1" ]; then
        ip=$(getent hosts "$hostname" 2>/dev/null | awk '{print $1}' | head -1)
    fi
    if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
        echo "$ip"
        return 0
    fi
    return 1
}

# Function to check if RTMP server is reachable
check_rtsp_server() {
    local hostname=$1
    local port=$2
    
    # If hostname is already an IP, use it directly; otherwise resolve it
    local ip=$hostname
    if [[ ! $hostname =~ ^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$ ]]; then
        ip=$(resolve_hostname "$hostname")
        if [ -z "$ip" ]; then
            log "Failed to resolve $hostname"
            return 1
        fi
        log "Resolved $hostname to $ip"
    fi
    
    # Test connection to RTMP server using resolved IP
    timeout $CONNECTION_TIMEOUT bash -c "</dev/tcp/$ip/$port" 2>/dev/null
    return $?
}

# Function to run the streaming command
run_stream() {
    local ip=$1
    local rtmp_url="rtmp://$ip:$RTSP_SERVER_PORT/$STREAM_NAME"
    log "Starting RPiCam RTMP stream to $rtmp_url"
    

#                                      number
#   --brightness arg (=0)                 Adjust the brightness of the output images, in the range -1.0 to 1.0
#   --contrast arg (=1)                   Adjust the contrast of the output image, where 1.0 = normal contrast
#   --saturation arg (=1)                 Adjust the colour saturation of the output, where 1.0 = normal and 0.0 = 
#                                         greyscale
#   --sharpness arg (=1)                  Adjust the sharpness of the output image, where 1.0 = normal sharpening
#   --framerate arg (=-1)                 Set the fixed framerate for preview and video modes

    # Stream to MediaMTX via RTMP (uses FLV container format for RTMP compatibility)
    rpicam-vid -t 0 --camera 0 --nopreview --codec yuv420 --brightness 0 --contrast 1 --saturation 1 --width 1280 --height 720 --framerate 30 --inline -o - | \
    ffmpeg -f rawvideo -pix_fmt yuv420p -s:v 1280x720 -r 30 -i - -c:v libx264 -preset veryfast -tune zerolatency -f flv "$rtmp_url"
}

# Main loop with retry logic
retry_count=0

while true; do
    # Check if we've exceeded max retries (if set)
    if [ $MAX_RETRIES -gt 0 ] && [ $retry_count -ge $MAX_RETRIES ]; then
        log "Maximum retry attempts ($MAX_RETRIES) reached. Exiting."
        exit 1
    fi
    
    # Wait for RTMP server to be available
    log "Checking RTMP server availability..."
    while ! check_rtsp_server "$RTSP_SERVER_DOMAIN" "$RTSP_SERVER_PORT"; do
        log "RTMP server at $RTSP_SERVER_DOMAIN:$RTSP_SERVER_PORT not reachable. Waiting $RETRY_DELAY seconds..."
        sleep $RETRY_DELAY
    done
    
    log "RTMP server is reachable. Starting stream (attempt $((retry_count + 1)))"
    
    # Get resolved IP for streaming
    resolved_ip=$(resolve_hostname "$RTSP_SERVER_DOMAIN")
    
    # Run the streaming command
    run_stream "$resolved_ip"
    
    # If we reach here, the command failed
    exit_code=$?
    retry_count=$((retry_count + 1))
    
    log "Stream failed with exit code $exit_code. Retrying in $RETRY_DELAY seconds..."
    sleep $RETRY_DELAY
done