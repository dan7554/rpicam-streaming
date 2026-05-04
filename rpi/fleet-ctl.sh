#!/bin/bash
set -euo pipefail

# fleet-ctl.sh — Multi-purpose control script for Pi camera fleet
# Usage: ./fleet-ctl.sh <action> [device1 device2 ...] [-- extra-args]
#
# Actions:
#   reboot              Reboot the Pi
#   stop-stream          Stop the camera stream (saves battery)
#   start-stream         Start the camera stream
#   restart-stream       Restart the camera stream
#   status               Show stream status + uptime
#   cli-mode             Set default boot to CLI (no desktop), reboot
#   gui-mode             Set default boot to desktop, reboot
#   set-wifi             Add/update WiFi: -- <ssid> <password> <priority>
#   deploy-agent         Deploy the health agent to the device(s)
#
# Devices: Tailscale hostnames (rpicam2, rpicam3) or IPs.
#          If none specified, applies to all known devices.
#
# Examples:
#   ./fleet-ctl.sh status                          # all devices
#   ./fleet-ctl.sh stop-stream rpicam3             # one device
#   ./fleet-ctl.sh reboot rpicam2 rpicam3          # multiple
#   ./fleet-ctl.sh set-wifi rpicam3 -- STARLINK pass123 100

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Known devices — edit this list as you add Pis
SSH_USER="${FLEET_SSH_USER:-pi}"
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o LogLevel=ERROR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Discover all rpicam* devices on the Tailscale network
discover_devices() {
    local devices=()
    if command -v tailscale &>/dev/null; then
        while IFS= read -r name; do
            [ -n "$name" ] && devices+=("$name")
        done < <(tailscale status --json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for k, v in data.get('Peer', {}).items():
    name = v.get('HostName', '')
    online = v.get('Online', False)
    if name.startswith('rpicam') and online:
        print(name)
" 2>/dev/null)
    fi
    if [ ${#devices[@]} -eq 0 ]; then
        echo -e "${YELLOW}No rpicam* devices found on Tailscale. Is Tailscale running?${NC}" >&2
        exit 1
    fi
    echo "${devices[@]}"
}

usage() {
    echo "Usage: $0 <action> [all | device1 device2 ...] [-- extra-args]"
    echo ""
    echo "Actions: reboot, stop-stream, start-stream, restart-stream,"
    echo "         status, cli-mode, gui-mode, set-wifi, deploy-agent"
    echo ""
    echo "Devices: 'all' = auto-discover rpicam* on Tailscale."
    echo "         Or specify hostnames/IPs. Default (no args): same as 'all'."
    exit 1
}

ACTION="${1:-}"
[ -z "$ACTION" ] && usage
shift

# Parse devices and extra args
DEVICES=()
EXTRA_ARGS=()
parsing_extra=false

for arg in "$@"; do
    if [ "$arg" = "--" ]; then
        parsing_extra=true
        continue
    fi
    if $parsing_extra; then
        EXTRA_ARGS+=("$arg")
    else
        DEVICES+=("$arg")
    fi
done

# Resolve device list: "all" or empty = auto-discover from Tailscale
if [ ${#DEVICES[@]} -eq 0 ] || [ "${DEVICES[0]}" = "all" ]; then
    read -ra DEVICES <<< "$(discover_devices)"
    echo -e "${CYAN}Discovered ${#DEVICES[@]} device(s): ${DEVICES[*]}${NC}"
    echo ""
fi

# Execute a command on a remote Pi
run_on() {
    local device="$1"
    shift
    ssh $SSH_OPTS "$SSH_USER@$device" "$@" 2>&1
}

# Check if device is reachable
check_device() {
    local device="$1"
    if ssh $SSH_OPTS "$SSH_USER@$device" "echo ok" &>/dev/null; then
        return 0
    fi
    return 1
}

do_status() {
    local dev="$1"
    echo -e "${CYAN}=== $dev ===${NC}"
    if ! check_device "$dev"; then
        echo -e "  ${RED}OFFLINE${NC}"
        return
    fi
    local stream_status uptime_str cpu_temp disk
    stream_status=$(run_on "$dev" "systemctl is-active rpicam-stream 2>/dev/null || echo inactive")
    uptime_str=$(run_on "$dev" "uptime -p 2>/dev/null || uptime")
    cpu_temp=$(run_on "$dev" "cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0")
    disk=$(run_on "$dev" "df -h / | tail -1 | awk '{print \$5}'")

    local temp_c=$((cpu_temp / 1000))
    local color=$GREEN
    [ "$stream_status" = "inactive" ] && color=$YELLOW
    [ "$stream_status" = "failed" ] && color=$RED

    echo -e "  Stream:  ${color}${stream_status}${NC}"
    echo -e "  Uptime:  $uptime_str"
    echo -e "  CPU:     ${temp_c}°C"
    echo -e "  Disk:    $disk used"
}

do_action() {
    local dev="$1"
    local action="$2"

    echo -e "${CYAN}[$dev]${NC} $action..."

    if ! check_device "$dev"; then
        echo -e "  ${RED}OFFLINE — skipping${NC}"
        return
    fi

    case "$action" in
        reboot)
            run_on "$dev" "sudo reboot" || true
            echo -e "  ${GREEN}Rebooting${NC}"
            ;;
        stop-stream)
            run_on "$dev" "sudo systemctl stop rpicam-stream"
            echo -e "  ${YELLOW}Stream stopped${NC}"
            ;;
        start-stream)
            run_on "$dev" "sudo systemctl start rpicam-stream"
            echo -e "  ${GREEN}Stream started${NC}"
            ;;
        restart-stream)
            run_on "$dev" "sudo systemctl restart rpicam-stream"
            echo -e "  ${GREEN}Stream restarted${NC}"
            ;;
        cli-mode)
            run_on "$dev" "sudo systemctl set-default multi-user.target"
            echo -e "  ${YELLOW}Set to CLI-only mode. Rebooting...${NC}"
            run_on "$dev" "sudo reboot" || true
            ;;
        gui-mode)
            run_on "$dev" "sudo systemctl set-default graphical.target"
            echo -e "  ${GREEN}Set to GUI mode. Rebooting...${NC}"
            run_on "$dev" "sudo reboot" || true
            ;;
        set-wifi)
            if [ ${#EXTRA_ARGS[@]} -lt 3 ]; then
                echo -e "  ${RED}Usage: set-wifi <device> -- <ssid> <password> <priority>${NC}"
                return
            fi
            local ssid="${EXTRA_ARGS[0]}"
            local pass="${EXTRA_ARGS[1]}"
            local prio="${EXTRA_ARGS[2]}"
            run_on "$dev" "sudo nmcli device wifi connect '$ssid' password '$pass' 2>/dev/null || sudo nmcli connection modify '$ssid' wifi-sec.key-mgmt wpa-psk wifi-sec.psk '$pass'"
            run_on "$dev" "sudo nmcli connection modify '$ssid' connection.autoconnect yes connection.autoconnect-priority $prio"
            echo -e "  ${GREEN}WiFi '$ssid' set with priority $prio${NC}"
            ;;
        deploy-agent)
            echo "  Copying health-agent.sh..."
            scp $SSH_OPTS "$SCRIPT_DIR/health-agent.sh" "$SSH_USER@$dev:/tmp/health-agent.sh"
            scp $SSH_OPTS "$SCRIPT_DIR/health-agent.service" "$SSH_USER@$dev:/tmp/health-agent.service"
            run_on "$dev" "sudo cp /tmp/health-agent.sh /usr/local/bin/health-agent.sh && sudo chmod +x /usr/local/bin/health-agent.sh"
            run_on "$dev" "sudo cp /tmp/health-agent.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now health-agent"
            echo -e "  ${GREEN}Health agent deployed and started${NC}"
            ;;
        *)
            echo -e "  ${RED}Unknown action: $action${NC}"
            ;;
    esac
}

# Execute
case "$ACTION" in
    status)
        for dev in "${DEVICES[@]}"; do
            do_status "$dev"
            echo ""
        done
        ;;
    *)
        for dev in "${DEVICES[@]}"; do
            do_action "$dev" "$ACTION"
        done
        ;;
esac
