#!/bin/bash

# Network switcher script for testing cellular vs WiFi

show_usage() {
    echo "Usage: $0 [cellular|wifi|status|auto]"
    echo ""
    echo "Commands:"
    echo "  cellular  - Switch to cellular connection (disable WiFi)"
    echo "  wifi      - Switch to WiFi connection (disable cellular)"
    echo "  status    - Show current network status"
    echo "  auto      - Enable both connections (automatic routing)"
    echo ""
}

show_status() {
    echo "=== Current Network Status ==="
    echo ""
    
    # Show Tailscale status first (most important for remote access)
    echo "🔵 Tailscale VPN Status:"
    if command -v tailscale >/dev/null 2>&1; then
        TAILSCALE_STATUS=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "unknown"' 2>/dev/null || echo "unknown")
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "unavailable")
        
        case $TAILSCALE_STATUS in
            "Running")
                echo "   ✅ Connected - IP: $TAILSCALE_IP"
                echo "   🌐 Remote access: ssh dan7554@$TAILSCALE_IP"
                ;;
            "NeedsLogin")
                echo "   🔑 Authentication required"
                echo "   💡 Run: sudo tailscale up --ssh --accept-routes"
                ;;
            "Stopped")
                echo "   ⏹️  Stopped"
                ;;
            *)
                echo "   ❓ Status: $TAILSCALE_STATUS"
                ;;
        esac
    else
        echo "   📦 Not installed (run: sudo ./setup-tailscale.sh)"
    fi
    echo ""
    
    echo "📡 Network Connections:"
    nmcli connection show --active
    echo ""
    echo "🛣️  Current routes:"
    ip route | head -5
    echo ""
    
    # Show IP addresses for all interfaces
    echo "📍 IP Addresses:"
    CELLULAR_IP=$(ip route get 1.1.1.1 2>/dev/null | grep rmnet_mhi0 | awk '{print $7}' | head -1 || echo "unavailable")
    WIFI_IP=$(ip route get 1.1.1.1 2>/dev/null | grep wlan0 | awk '{print $7}' | head -1 || echo "unavailable")
    
    echo "   📱 Cellular:  $CELLULAR_IP"
    echo "   📶 WiFi:      $WIFI_IP"
    echo "   🔵 Tailscale: $TAILSCALE_IP"
    echo ""
    
    echo "🌐 Internet connectivity test:"
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        echo "   ✅ Internet connectivity: OK"
        echo "   🌍 Current public IP:"
        PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "Could not determine")
        echo "      $PUBLIC_IP"
    else
        echo "   ❌ Internet connectivity: FAILED"
    fi
    echo ""
    
    echo "🔧 Interface Details:"
    ip addr show rmnet_mhi0 | grep -E "(rmnet_mhi0|inet)" 2>/dev/null || echo "   Cellular: DOWN"
    ip addr show wlan0 | grep -E "(wlan0|inet)" 2>/dev/null || echo "   WiFi: DOWN"
    
    # Show reverse tunnel status if available
    if [ -f "/home/dan7554/reverse-tunnel-manager.sh" ] && systemctl is-active --quiet reverse-ssh-tunnel 2>/dev/null; then
        echo ""
        echo "🔄 Reverse Tunnel: Active (backup access available)"
    fi
}

switch_to_cellular() {
    echo "🔄 Switching to cellular connection..."
    
    # Find cellular connection (any 5G/GSM connection)
    CELLULAR_CONNECTION=$(nmcli connection show | grep -E "(5G|gsm|cellular)" | head -1 | awk '{print $1}')
    
    if [ -z "$CELLULAR_CONNECTION" ]; then
        echo "❌ No cellular connection found. Available connections:"
        nmcli connection show | grep -E "(Verizon|eiotclub|MintMobile|5G)"
        echo "💡 Run setup-cellular-connection.sh first"
        return 1
    fi
    
    echo "Using cellular connection: $CELLULAR_CONNECTION"
    
    # Bring up cellular
    echo "Activating cellular connection..."
    sudo nmcli connection up "$CELLULAR_CONNECTION"
    
    # Disable WiFi
    echo "Disabling WiFi..."
    sudo nmcli radio wifi off
    
    # Wait a moment
    sleep 3
    
    echo "✅ Switched to cellular ($CELLULAR_CONNECTION)"
    show_status
}

switch_to_wifi() {
    echo "🔄 Switching to WiFi connection..."
    
    # Find and bring down any cellular connection
    CELLULAR_CONNECTIONS=$(nmcli connection show --active | grep -E "(5G|gsm|cellular)" | awk '{print $1}')
    
    if [ -n "$CELLULAR_CONNECTIONS" ]; then
        echo "Deactivating cellular connections..."
        echo "$CELLULAR_CONNECTIONS" | while read -r conn; do
            sudo nmcli connection down "$conn" 2>/dev/null || true
        done
    fi
    
    # Enable WiFi
    echo "Enabling WiFi..."
    sudo nmcli radio wifi on
    
    # Find and connect to WiFi
    WIFI_CONNECTION=$(nmcli connection show | grep wifi | head -1 | awk '{print $1}')
    
    if [ -n "$WIFI_CONNECTION" ]; then
        echo "Connecting to WiFi ($WIFI_CONNECTION)..."
        sudo nmcli connection up "$WIFI_CONNECTION"
    else
        echo "⚠️ No WiFi connection found. Scanning for networks..."
        nmcli device wifi list | head -5
    fi
    
    # Wait a moment
    sleep 3
    
    echo "✅ Switched to WiFi"
    show_status
}

enable_both() {
    echo "🔄 Enabling both connections with automatic routing..."
    
    # Enable WiFi
    sudo nmcli radio wifi on
    
    # Find and connect to WiFi
    WIFI_CONNECTION=$(nmcli connection show | grep wifi | head -1 | awk '{print $1}')
    if [ -n "$WIFI_CONNECTION" ]; then
        sudo nmcli connection up "$WIFI_CONNECTION"
        # Set WiFi as preferred (higher priority)
        sudo nmcli connection modify "$WIFI_CONNECTION" connection.autoconnect-priority 100
    fi
    
    # Find and enable cellular
    CELLULAR_CONNECTION=$(nmcli connection show | grep -E "(5G|gsm|cellular)" | head -1 | awk '{print $1}')
    if [ -n "$CELLULAR_CONNECTION" ]; then
        sudo nmcli connection up "$CELLULAR_CONNECTION"
        # Set cellular as backup (lower priority)
        sudo nmcli connection modify "$CELLULAR_CONNECTION" connection.autoconnect-priority 50
    fi
    
    echo "✅ Both connections enabled (WiFi preferred, cellular backup)"
    show_status
}

# Main script
case "$1" in
    "cellular"|"cell"|"5g")
        switch_to_cellular
        ;;
    "wifi"|"wlan")
        switch_to_wifi
        ;;
    "status"|"stat")
        show_status
        ;;
    "auto"|"both")
        enable_both
        ;;
    *)
        show_usage
        exit 1
        ;;
esac