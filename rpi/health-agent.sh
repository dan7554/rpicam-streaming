#!/bin/bash
# health-agent.sh — Heartbeat agent for Pi camera fleet
# Reports device health to the streaming server every 30 seconds.
# Install: sudo cp health-agent.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/health-agent.sh
# Config via env vars in /etc/health-agent.conf:
#   SERVER_URL=http://stream.racetrackstreaming.com:8080
#   DEVICE_NAME=rpicam3

set -uo pipefail

CONF="/etc/health-agent.conf"
[ -f "$CONF" ] && source "$CONF"

SERVER_URL="${SERVER_URL:-http://localhost:8080}"
DEVICE_NAME="${DEVICE_NAME:-$(hostname)}"
INTERVAL="${INTERVAL:-30}"

log() { echo "[health-agent] $(date '+%H:%M:%S') $*"; }

get_cpu_temp() {
    local raw
    raw=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "0")
    echo "$((raw / 1000))"
}

get_uptime_secs() {
    awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0"
}

get_disk_pct() {
    df / 2>/dev/null | tail -1 | awk '{gsub(/%/,""); print $5}'
}

get_stream_active() {
    if systemctl is-active rpicam-stream &>/dev/null; then
        echo "true"
    else
        echo "false"
    fi
}

get_stream_enabled() {
    if systemctl is-enabled rpicam-stream &>/dev/null; then
        echo "true"
    else
        echo "false"
    fi
}

get_tailscale_ip() {
    tailscale ip -4 2>/dev/null || echo ""
}

get_local_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || echo ""
}

get_starlink_stats() {
    # Try pinging the Starlink dish to check connectivity
    local dish_ip="192.168.100.1"
    local reachable="false"
    local latency_ms="0"

    if ping_output=$(ping -c 1 -W 2 "$dish_ip" 2>/dev/null); then
        reachable="true"
        latency_ms=$(echo "$ping_output" | grep 'time=' | sed 's/.*time=\([0-9.]*\).*/\1/' | head -1)
        [ -z "$latency_ms" ] && latency_ms="0"
    fi

    # Try grpcurl for detailed stats (optional, requires grpcurl + proto files)
    local downlink="0"
    local uplink="0"
    local obstructed="false"
    local dish_uptime="0"

    if command -v grpcurl &>/dev/null; then
        local grpc_out
        if grpc_out=$(grpcurl -plaintext -d '{"getStatus":{}}' "$dish_ip:9200" SpaceX.API.Device.Device/Handle 2>/dev/null); then
            downlink=$(echo "$grpc_out" | grep -o '"downlinkThroughputBps":[0-9.]*' | cut -d: -f2 | head -1)
            uplink=$(echo "$grpc_out" | grep -o '"uplinkThroughputBps":[0-9.]*' | cut -d: -f2 | head -1)
            dish_uptime=$(echo "$grpc_out" | grep -o '"deviceState":{[^}]*"uptimeS":[0-9]*' | grep -o '"uptimeS":[0-9]*' | cut -d: -f2 | head -1)
            # Convert bps to Mbps
            [ -n "$downlink" ] && downlink=$(awk "BEGIN{printf \"%.1f\", $downlink/1000000}")
            [ -n "$uplink" ] && uplink=$(awk "BEGIN{printf \"%.1f\", $uplink/1000000}")
            if echo "$grpc_out" | grep -q '"obstructed":true'; then
                obstructed="true"
            fi
        fi
    fi

    cat <<EOF
"reachable":$reachable,"latencyMs":$latency_ms,"downlinkMbps":${downlink:-0},"uplinkMbps":${uplink:-0},"obstructed":$obstructed,"uptimeS":${dish_uptime:-0}
EOF
}

get_boot_mode() {
    local target
    target=$(systemctl get-default 2>/dev/null || echo "unknown")
    case "$target" in
        multi-user.target) echo "cli" ;;
        graphical.target)  echo "gui" ;;
        *)                 echo "$target" ;;
    esac
}

send_heartbeat() {
    local cpu_temp uptime_s disk_pct stream_active stream_enabled ts_ip local_ip starlink boot_mode
    cpu_temp=$(get_cpu_temp)
    uptime_s=$(get_uptime_secs)
    disk_pct=$(get_disk_pct)
    stream_active=$(get_stream_active)
    stream_enabled=$(get_stream_enabled)
    ts_ip=$(get_tailscale_ip)
    local_ip=$(get_local_ip)
    starlink=$(get_starlink_stats | tr -d '\n')
    boot_mode=$(get_boot_mode)

    local payload
    payload=$(cat <<EOF
{"device":"$DEVICE_NAME","tailscaleIp":"$ts_ip","localIp":"$local_ip","cpuTemp":$cpu_temp,"uptimeS":$uptime_s,"diskPct":$disk_pct,"streamActive":$stream_active,"streamEnabled":$stream_enabled,"bootMode":"$boot_mode","starlink":{$starlink}}
EOF
    )

    if curl -s -X POST -H "Content-Type: application/json" -d "$payload" \
        "${SERVER_URL}/api/fleet/heartbeat" -o /dev/null -w "%{http_code}" 2>/dev/null | grep -q "200"; then
        return 0
    else
        return 1
    fi
}

# Main loop
log "starting: device=$DEVICE_NAME server=$SERVER_URL interval=${INTERVAL}s"

while true; do
    if send_heartbeat; then
        log "heartbeat sent"
    else
        log "heartbeat FAILED (server unreachable?)"
    fi
    sleep "$INTERVAL"
done
