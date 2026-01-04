#!/bin/bash

# Configuration
PI_USER="dan7554"
PI_HOST_WIFI="192.168.50.96"  # WiFi hostname
PI_HOST_TAILSCALE="100.80.96.23"  # Tailscale IP (rpicam2)
PI_HOST_IP="192.168.50.96"  # WiFi static IP (fallback)

# Default to deploying to all cameras on Tailscale
PI_HOST="$PI_HOST_TAILSCALE"
CONNECTION_TYPE="tailscale"
DEPLOY_ALL=1

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --single)
            DEPLOY_ALL=0
            shift
            ;;
        --tailscale)
            DEPLOY_ALL=0
            PI_HOST="$PI_HOST_TAILSCALE"
            CONNECTION_TYPE="tailscale"
            shift
            ;;
        --wifi)
            DEPLOY_ALL=0
            PI_HOST="$PI_HOST_WIFI"
            CONNECTION_TYPE="wifi"
            shift
            ;;
        --ip)
            DEPLOY_ALL=0
            PI_HOST="$PI_HOST_IP"
            CONNECTION_TYPE="ip"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--single|--wifi|--tailscale|--ip]"
            echo "  (default)    Deploy to all RPi cameras found on Tailscale"
            echo "  --single     Deploy to single camera (rpicam2 via Tailscale)"
            echo "  --wifi       Deploy to single camera via WiFi (rpicam2.local)"
            echo "  --tailscale  Deploy to single camera via Tailscale VPN (100.80.96.23)"
            echo "  --ip         Deploy to single camera via static IP (192.168.50.96)"
            exit 1
            ;;
    esac
done

# Function to deploy to a single camera
deploy_to_camera() {
    local target_host=$1
    local camera_name=$2
    
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "📹 Deploying to: $camera_name ($target_host)"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    echo "═══════════════════════════════════════════════════════"
    echo "📹 Deploying to: $camera_name ($target_host)"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    echo "Copying files to Raspberry Pi..."
    # RPi camera streaming files
    eval $SCP_CMD rpi/install.sh $PI_USER@$target_host:/home/dan7554/
    eval $SCP_CMD rpi/logs.sh $PI_USER@$target_host:/home/dan7554/
    eval $SCP_CMD rpi/stop.sh $PI_USER@$target_host:/home/dan7554/
    eval $SCP_CMD rpi/start.sh $PI_USER@$target_host:/home/dan7554/
    eval $SCP_CMD rpi/rpicam-stream.sh $PI_USER@$target_host:/home/dan7554/
    eval $SCP_CMD rpi/rpicam-stream.service $PI_USER@$target_host:/home/dan7554/
    eval $SCP_CMD rpi/wifi-switcher.sh $PI_USER@$target_host:/home/dan7554/

    # Copy MediaMTX host config if we got the IP
    if [ -f /tmp/mediamtx-host.tmp ]; then
        eval $SCP_CMD /tmp/mediamtx-host.tmp $PI_USER@$target_host:/home/dan7554/.mediamtx-host
    fi

    # Remote access scripts (Tailscale & backup tunnel)
    eval $SCP_CMD rpi/setup-tailscale.sh $PI_USER@$target_host:/home/dan7554/
    eval $SCP_CMD rpi/reverse-ssh-tunnel.sh $PI_USER@$target_host:/home/dan7554/

    echo "Installing and starting service..."
    eval $SSH_CMD $PI_USER@$target_host << 'EOF'
# Make RPi camera script executable
chmod +x /home/dan7554/rpicam-stream.sh
chmod +x /home/dan7554/setup-tailscale.sh
chmod +x /home/dan7554/reverse-ssh-tunnel.sh
chmod +x /home/dan7554/complete-mobile-setup.sh
chmod +x /home/dan7554/stop.sh
chmod +x /home/dan7554/wifi-switcher.sh

# Install and start RPi camera service
sudo cp /home/dan7554/rpicam-stream.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable rpicam-stream.service
sudo systemctl restart rpicam-stream.service

echo "📹 RPi Camera Service status:"
sudo systemctl status rpicam-stream.service --no-pager
EOF

    echo "✅ Deployment complete for $camera_name"
}

# Use SSH keys for authentication
SCP_CMD="scp"
SSH_CMD="ssh"

if [ $DEPLOY_ALL -eq 1 ]; then
    echo "🔍 Discovering Raspberry Pi cameras on Tailscale..."
    
    # Get all Tailscale devices with 'rpicam' in the hostname
    CAMERAS=$(tailscale status --json | jq -r '.Peer[] | select(.HostName | test("rpicam")) | "\(.TailscaleIPs[0])|\(.HostName)"' 2>/dev/null)
    
    if [ -z "$CAMERAS" ]; then
        echo "❌ No cameras found on Tailscale with 'rpicam' in hostname"
        echo "   Make sure Tailscale is running and cameras are connected"
        exit 1
    fi
    
    # Count cameras
    CAMERA_COUNT=$(echo "$CAMERAS" | wc -l | tr -d ' ')
    
    echo "═══════════════════════════════════════════════════════"
    echo "📹 Found $CAMERA_COUNT camera(s) on Tailscale:"
    echo "═══════════════════════════════════════════════════════"
    echo "$CAMERAS" | while IFS='|' read -r ip hostname; do
        echo "  - $hostname ($ip)"
    done
    echo ""
    
    # Prompt for confirmation
    read -p "Deploy to all $CAMERA_COUNT cameras? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "❌ Deployment cancelled"
        exit 0
    fi
    echo ""
    
    # Use public MediaMTX domain (no need to query AWS)
    echo "🔍 Configuring MediaMTX host..."
    MEDIAMTX_HOST="mediamtx.racetrackstreaming.com"
    echo "✅ MediaMTX Host: $MEDIAMTX_HOST"
    echo "$MEDIAMTX_HOST" > /tmp/mediamtx-host.tmp
    echo ""
    
    # Deploy to each camera
    echo "$CAMERAS" | while IFS='|' read -r ip hostname; do
        deploy_to_camera "$ip" "$hostname"
    done
    
    # Cleanup temp file
    rm -f /tmp/mediamtx-host.tmp
    
    echo ""
    echo "✅ Deployment complete to all cameras!"
    
else
    # Single camera deployment (original behavior)
    echo "📡 Connection Type: $CONNECTION_TYPE"
    echo "🎯 Target Host: $PI_HOST"
    echo ""

    # Use public MediaMTX domain (no need to query AWS)
    echo "🔍 Configuring MediaMTX host..."
    MEDIAMTX_HOST="mediamtx.racetrackstreaming.com"
    echo "✅ MediaMTX Host: $MEDIAMTX_HOST"
    # Create a temporary config file with the host
    echo "$MEDIAMTX_HOST" > /tmp/mediamtx-host.tmp
    echo ""

    deploy_to_camera "$PI_HOST" "rpicam"
    
    # Cleanup temp file
    rm -f /tmp/mediamtx-host.tmp
    
    echo ""
    echo "✅ Deployment complete!"
fi