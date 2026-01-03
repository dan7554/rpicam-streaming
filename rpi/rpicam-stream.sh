#!/bin/bash

# RPiCam RTSP Stream Script with Retry Logic
# This script runs the rpicam-vid command with automatic retry on failure

# Logging function (defined first so it can be used in config)
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Configuration
# NOTE: Use direct IP address to bypass CloudFlare proxy (CloudFlare doesn't support RTMP/RTSP)
# When MediaMTX ECS task is redeployed, update IP using:
# aws ecs describe-tasks --cluster mediamtx-cluster --tasks $(aws ecs list-tasks --cluster mediamtx-cluster --region us-east-2 --query 'taskArns[0]' --output text) --region us-east-2 --query 'tasks[0].attachments[?type==`ElasticNetworkInterface`].details[?name==`primaryPublicIpv4Address`].value' --output text
RTSP_SERVER_DOMAIN="13.59.160.208"  # Direct public IP of MediaMTX ECS task (bypasses CloudFlare proxy)

# Check if config file exists and use it if no CLI host is provided
if [ -f "$HOME/.mediamtx-host" ] && [ -z "$MEDIAMTX_HOST_OVERRIDE" ]; then
    RTSP_SERVER_DOMAIN=$(cat "$HOME/.mediamtx-host")
    log "Using MediaMTX host from config: $RTSP_SERVER_DOMAIN"
fi

RTSP_SERVER_PORT="1935"  # RTMP port (not RTSP 8554)

# Auto-detect camera name from hostname or Tailscale
# Try: tailscale status, fallback to system hostname, fallback to hardcoded rpicam2
detect_camera_name() {
    # Try Tailscale hostname first
    if command -v tailscale >/dev/null 2>&1; then
        local ts_name=$(tailscale status --json 2>/dev/null | jq -r '.Self.HostName' 2>/dev/null)
        if [ -n "$ts_name" ] && [ "$ts_name" != "null" ]; then
            echo "$ts_name"
            return
        fi
    fi
    
    # Fallback to system hostname
    local sys_name=$(hostname 2>/dev/null | sed 's/\.local$//')
    if [ -n "$sys_name" ]; then
        echo "$sys_name"
        return
    fi
    
    # Last resort fallback
    echo "rpicam2"
}

STREAM_NAME=$(detect_camera_name)
MAX_RETRIES=0  # 0 means infinite retries
RETRY_DELAY=5  # seconds between retries
CONNECTION_TIMEOUT=30  # seconds to wait for RTSP server
DNS_SERVER="8.8.8.8"  # Google DNS - works on cellular when carrier DNS fails

# Usage/help
usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --mediamtx-host HOST     Use HOST as the MediaMTX host (IP or hostname)
  --local-mediamtx         Detect the SSH client IP and use it as MediaMTX host
  -h, --help               Show this help message

Stream Name:
  The camera stream name is auto-detected from:
  1. Tailscale hostname (TS_NAME.ts.net) -> TS_NAME
  2. System hostname (rpicam2.local) -> rpicam2
  3. Fallback to 'rpicam2'

When --local-mediamtx is used the script will try to extract the SSH client IP
from the SSH environment (SSH_CONNECTION / SSH_CLIENT). This is useful when
running the script on a Raspberry Pi while MediaMTX runs on your machine.
EOF
}

# Parse CLI args (allow overriding the RTMP/RTSP host)
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mediamtx-host)
            RTSP_SERVER_DOMAIN="$2"
            MEDIAMTX_HOST_OVERRIDE=1
            shift 2
            ;;
        --mediamtx-host=*)
            RTSP_SERVER_DOMAIN="${1#*=}"
            MEDIAMTX_HOST_OVERRIDE=1
            shift
            ;;
        --local-mediamtx)
            # Prefer SSH-provided client IP if available
            if [ -n "$SSH_CONNECTION" ]; then
                client_ip=$(echo "$SSH_CONNECTION" | awk '{print $1}')
            elif [ -n "$SSH_CLIENT" ]; then
                client_ip=$(echo "$SSH_CLIENT" | awk '{print $1}')
            else
                # Fallback: try to infer local IP used for outbound traffic
                if command -v ip >/dev/null 2>&1; then
                    client_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
                else
                    client_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
                fi
            fi
            if [ -n "$client_ip" ]; then
                RTSP_SERVER_DOMAIN="$client_ip"
                MEDIAMTX_HOST_OVERRIDE=1
                log "Using detected local MediaMTX host: $RTSP_SERVER_DOMAIN"
            else
                log "Could not detect local MediaMTX host via SSH vars or route; leaving default host"
            fi
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

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