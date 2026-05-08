#!/bin/bash
# Power mode control for Raspberry Pi cameras
# Usage: ./power-mode.sh [sleep|stream] [cam1|cam3|all]

set -e

USER="dan7554"
PW='!Dan1007554'

MODE="${1:-}"
TARGET="${2:-all}"

# Get IP for camera name from Tailscale
get_ip() {
    local cam="$1"
    # Query tailscale for the IP, looking for hostname containing camera name
    # e.g. "rpicam1" matches "cam1"
    tailscale status --json 2>/dev/null | \
        python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    cam = '$cam'
    # Check peers
    for peer in data.get('Peer', {}).values():
        hostname = peer.get('HostName', '').lower()
        if cam in hostname or hostname == cam:
            ips = peer.get('TailscaleIPs', [])
            if ips:
                print(ips[0])
                sys.exit(0)
    # Check self
    self_host = data.get('Self', {}).get('HostName', '').lower()
    if cam in self_host or self_host == cam:
        ips = data.get('Self', {}).get('TailscaleIPs', [])
        if ips:
            print(ips[0])
except:
    pass
"
}

# List all cameras from Tailscale
list_cameras() {
    tailscale status --json 2>/dev/null | \
        python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for peer in data.get('Peer', {}).values():
        hostname = peer.get('HostName', '')
        if 'cam' in hostname.lower() or 'rpi' in hostname.lower():
            ips = peer.get('TailscaleIPs', [])
            if ips:
                print(hostname)
except:
    pass
"
}

usage() {
    echo "Usage: $0 [sleep|stream] [cam1|cam3|all]"
    echo ""
    echo "Modes:"
    echo "  sleep   - Low power: stop streaming, disable HDMI/USB/BT, reduce CPU"
    echo "  stream  - Normal power: start streaming, enable USB, normal CPU"
    echo ""
    echo "Available cameras (from Tailscale):"
    list_cameras | while read cam; do
        ip=$(get_ip "$cam")
        echo "  $cam ($ip)"
    done
    exit 1
}

if [ -z "$MODE" ] || { [ "$MODE" != "sleep" ] && [ "$MODE" != "stream" ]; }; then
    usage
fi

# Build target list
if [ "$TARGET" = "all" ]; then
    TARGETS=$(list_cameras | tr '\n' ' ')
    if [ -z "$TARGETS" ]; then
        echo "No cameras found in Tailscale"
        exit 1
    fi
else
    IP=$(get_ip "$TARGET")
    if [ -z "$IP" ]; then
        echo "Camera '$TARGET' not found in Tailscale"
        echo ""
        echo "Available cameras:"
        list_cameras
        exit 1
    fi
    TARGETS="$TARGET"
fi

# Remote script for sleep mode
SLEEP_SCRIPT='
echo "=== Entering sleep mode ==="

# Stop streaming service
echo "Stopping streaming service..."
systemctl stop rpicam-stream 2>/dev/null || true
systemctl disable rpicam-stream 2>/dev/null || true

# Stop health agent (status reporting)
echo "Stopping health agent..."
systemctl stop health-agent 2>/dev/null || true
systemctl disable health-agent 2>/dev/null || true

# Disable HDMI
echo "Disabling HDMI..."
if command -v tvservice &>/dev/null; then
    tvservice -o 2>/dev/null || true
else
    # Pi 5 uses different method
    echo 1 > /sys/class/backlight/*/bl_power 2>/dev/null || true
fi

# Disable Bluetooth
echo "Disabling Bluetooth..."
rfkill block bluetooth 2>/dev/null || true

# Disable USB hub (Pi 5 only - Pi Zero needs USB for some things)
MACHINE=$(cat /proc/device-tree/model 2>/dev/null || echo "unknown")
if [[ "$MACHINE" == *"Pi 5"* ]]; then
    echo "Disabling USB controller..."
    for usb in /sys/bus/usb/drivers/usb/usb*; do
        basename "$usb" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null || true
    done
fi

# Set CPU to powersave
echo "Setting CPU to powersave..."
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo powersave > "$cpu" 2>/dev/null || true
done

# Fan will slow automatically as temp drops in powersave mode

# Disable LEDs
echo "Disabling LEDs..."
echo none > /sys/class/leds/ACT/trigger 2>/dev/null || true
echo 0 > /sys/class/leds/ACT/brightness 2>/dev/null || true
echo none > /sys/class/leds/PWR/trigger 2>/dev/null || true
echo 0 > /sys/class/leds/PWR/brightness 2>/dev/null || true

echo "=== Sleep mode active ==="
echo "WiFi and Tailscale remain active"
'

# Remote script for stream mode
STREAM_SCRIPT='
echo "=== Entering stream mode ==="

MACHINE=$(cat /proc/device-tree/model 2>/dev/null || echo "unknown")

# Re-enable USB hub (Pi 5 only)
if [[ "$MACHINE" == *"Pi 5"* ]]; then
    echo "Re-enabling USB controller..."
    for usb in 1-1 2-1 3-1 4-1; do
        echo "$usb" > /sys/bus/usb/drivers/usb/bind 2>/dev/null || true
    done
    # Give USB time to enumerate
    sleep 2
fi

# Set CPU to ondemand (balanced performance)
echo "Setting CPU to ondemand..."
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo ondemand > "$cpu" 2>/dev/null || echo schedutil > "$cpu" 2>/dev/null || true
done

# Fan is temperature-controlled, no action needed

# Re-enable LEDs
echo "Re-enabling LEDs..."
echo mmc0 > /sys/class/leds/ACT/trigger 2>/dev/null || true
echo default-on > /sys/class/leds/PWR/trigger 2>/dev/null || true

# Enable and start health agent
echo "Starting health agent..."
systemctl enable health-agent 2>/dev/null || true
systemctl start health-agent 2>/dev/null || true

# Enable and start streaming service
echo "Starting streaming service..."
systemctl enable rpicam-stream 2>/dev/null || true
systemctl start rpicam-stream

# Wait for service to start
sleep 3

# Check status
if systemctl is-active --quiet rpicam-stream; then
    echo "=== Stream mode active ==="
else
    echo "WARNING: Streaming service may not have started correctly"
    systemctl status rpicam-stream --no-pager -l || true
fi
'

# Execute on each target
for cam in $TARGETS; do
    IP=$(get_ip "$cam")
    echo ""
    echo "=========================================="
    echo "Configuring $cam ($IP) for $MODE mode"
    echo "=========================================="
    
    if [ "$MODE" = "sleep" ]; then
        SCRIPT="$SLEEP_SCRIPT"
    else
        SCRIPT="$STREAM_SCRIPT"
    fi
    
    # SSH and run script with sudo
    ssh -o ConnectTimeout=10 "$USER@$IP" "printf '%s\n' '$PW' | sudo -S bash -c '$SCRIPT'" 2>&1
    
    if [ $? -eq 0 ]; then
        echo "✓ $cam configured for $MODE mode"
    else
        echo "✗ Failed to configure $cam"
    fi
done

echo ""
echo "Done."
