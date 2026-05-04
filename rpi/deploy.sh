#!/bin/bash
set -euo pipefail

# Deploy RPiCam streaming to a Raspberry Pi
# Usage: ./deploy.sh <pi-host> [mediamtx-ip]
#   pi-host:     SSH target for the Pi (e.g. rpicam3)
#   mediamtx-ip: IP of the MediaMTX server (default: auto-detect Tailscale IP)
#
# On boot the Pi will push its camera as RTMP to the MediaMTX server.
# Stream name is auto-detected from hostname: rpicam3 → cam3
#
# Requires on the Mac:
#   tailscale serve --bg --tcp 1935 tcp://localhost:1935

PI_HOST="${1:?Usage: $0 <pi-host> [mediamtx-ip]}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Auto-detect server IP: prefer Tailscale IP of this Mac
if [ -n "${2:-}" ]; then
    SERVER_IP="$2"
else
    SERVER_IP=$(tailscale ip -4 2>/dev/null || true)
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(ssh "$PI_HOST" 'echo $SSH_CLIENT' | awk '{print $1}')
        echo "No Tailscale; using SSH client IP: $SERVER_IP"
    else
        echo "Using Tailscale IP: $SERVER_IP"
    fi
fi

echo "=== RPiCam Deploy ==="
echo "  Pi:         $PI_HOST"
echo "  Server:     $SERVER_IP:1935 (RTMP)"
echo ""

# 1. Check connectivity
echo "[1/6] Checking SSH to Pi..."
ssh -o ConnectTimeout=5 "$PI_HOST" "echo OK" || { echo "Cannot reach $PI_HOST"; exit 1; }

# 2. Tailscale — install if missing, ensure auto-start
echo "[2/6] Checking Tailscale..."
TAILSCALE_INSTALLED=$(ssh "$PI_HOST" "command -v tailscale &>/dev/null && echo yes || echo no")
if [ "$TAILSCALE_INSTALLED" = "no" ]; then
    echo "  Installing Tailscale..."
    scp "$SCRIPT_DIR/setup-tailscale.sh" "$PI_HOST:/tmp/setup-tailscale.sh"
    ssh "$PI_HOST" "sudo bash /tmp/setup-tailscale.sh"
    echo ""
    echo "  ⚠️  Tailscale needs authentication."
    echo "  Running 'tailscale up --ssh' — follow the URL to authorize:"
    echo ""
    ssh -t "$PI_HOST" "sudo tailscale up --ssh --accept-routes"
    echo ""
    TS_IP=$(ssh "$PI_HOST" "tailscale ip -4 2>/dev/null || echo 'pending'")
    echo "  Tailscale IP: $TS_IP"
else
    TS_STATUS=$(ssh "$PI_HOST" "systemctl is-active tailscaled 2>/dev/null || echo inactive")
    TS_IP=$(ssh "$PI_HOST" "tailscale ip -4 2>/dev/null || echo 'unknown'")
    echo "  Tailscale already installed: $TS_STATUS (IP: $TS_IP)"
    # Ensure services are enabled
    ssh "$PI_HOST" "sudo systemctl enable tailscaled 2>/dev/null"
fi

# 3. Check camera
echo "[3/6] Checking camera..."
cam_check=$(ssh "$PI_HOST" "rpicam-vid --list-cameras 2>&1")
if echo "$cam_check" | grep -q "Available cameras"; then
    echo "  Camera found: $(echo "$cam_check" | grep '^[0-9]')"
else
    echo "  WARNING: No camera detected on $PI_HOST"
    read -rp "  Continue anyway? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || exit 1
fi

# 4. Copy files
echo "[4/6] Deploying files..."
ssh "$PI_HOST" "sudo mkdir -p /opt/rpicam-stream"
scp "$SCRIPT_DIR/rpicam-stream.sh" "$PI_HOST:/tmp/rpicam-stream.sh"
scp "$SCRIPT_DIR/rpicam-stream.service" "$PI_HOST:/tmp/rpicam-stream.service"
ssh "$PI_HOST" "
    sudo mv /tmp/rpicam-stream.sh /opt/rpicam-stream/rpicam-stream.sh
    sudo chmod +x /opt/rpicam-stream/rpicam-stream.sh
    sudo mv /tmp/rpicam-stream.service /etc/systemd/system/rpicam-stream.service
    echo 'MEDIAMTX_HOST=$SERVER_IP' | sudo tee /etc/rpicam-stream.conf > /dev/null
    echo 'AUDIO_DEVICE=hw:2,0' | sudo tee -a /etc/rpicam-stream.conf > /dev/null
    sudo systemctl daemon-reload
"

# 5. Enable and start
echo "[5/6] Starting service..."
ssh "$PI_HOST" "
    sudo systemctl stop rpicam-stream 2>/dev/null || true
    sudo systemctl enable rpicam-stream
    sudo systemctl start rpicam-stream
"

# 6. Verify
echo "[6/6] Verifying..."
sleep 5
ssh "$PI_HOST" "
    echo '--- Service ---'
    systemctl is-active rpicam-stream && echo '  Status: RUNNING' || echo '  Status: FAILED'
    echo '--- Config ---'
    cat /etc/rpicam-stream.conf
    echo '--- Recent logs ---'
    journalctl -u rpicam-stream --no-pager -n 8 2>&1
"

stream_name=$(ssh "$PI_HOST" "hostname | sed 's/rpicam/cam/'")
echo ""
echo "=== Deploy complete ==="
echo "  Stream name: $stream_name"
echo "  Target: rtmp://$SERVER_IP:1935/$stream_name"
echo "  View: http://localhost:8080 (select $stream_name)"
echo "  Logs: ssh $PI_HOST 'journalctl -fu rpicam-stream'"
echo ""
echo "  If behind a Mac firewall, start a tunnel from this machine:"
echo "    ssh -R 1935:localhost:1935 -N $PI_HOST"
echo "  Then: ssh $PI_HOST 'sudo sed -i s/MEDIAMTX_HOST=.*/MEDIAMTX_HOST=127.0.0.1/ /etc/rpicam-stream.conf && sudo systemctl restart rpicam-stream'"
