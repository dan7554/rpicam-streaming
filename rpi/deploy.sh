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
echo "[1/5] Checking SSH to Pi..."
ssh -o ConnectTimeout=5 "$PI_HOST" "echo OK" || { echo "Cannot reach $PI_HOST"; exit 1; }

# 2. Check camera
echo "[2/5] Checking camera..."
cam_check=$(ssh "$PI_HOST" "rpicam-vid --list-cameras 2>&1")
if echo "$cam_check" | grep -q "Available cameras"; then
    echo "  Camera found: $(echo "$cam_check" | grep '^[0-9]')"
else
    echo "  WARNING: No camera detected on $PI_HOST"
    read -rp "  Continue anyway? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || exit 1
fi

# 3. Copy files
echo "[3/5] Deploying files..."
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

# 4. Enable and start
echo "[4/5] Starting service..."
ssh "$PI_HOST" "
    sudo systemctl stop rpicam-stream 2>/dev/null || true
    sudo systemctl enable rpicam-stream
    sudo systemctl start rpicam-stream
"

# 5. Verify
echo "[5/5] Verifying..."
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
