#!/bin/bash

# Cellular Routing Fix for SIM8262A-M2
# This script configures proper routing for cellular interface to support Tailscale

set -e

echo "🔧 Cellular Routing Fix for SIM8262A-M2"
echo "========================================"

# Function to configure cellular routing
configure_cellular_routing() {
    echo "🚀 Configuring cellular interface routing..."
    
    # Check if rmnet_mhi0 exists
    if ! ip link show rmnet_mhi0 >/dev/null 2>&1; then
        echo "❌ rmnet_mhi0 interface not found"
        return 1
    fi
    
    # Get current interface status
    echo "📊 Current rmnet_mhi0 status:"
    ip addr show rmnet_mhi0
    
    # Bring interface up if it's down
    if ip link show rmnet_mhi0 | grep -q "state DOWN"; then
        echo "🔧 Bringing rmnet_mhi0 interface up..."
        sudo ip link set rmnet_mhi0 up
    fi
    
    # Check if we have an IP assigned
    if ! ip addr show rmnet_mhi0 | grep -q "inet "; then
        echo "⚠️ No IP address on rmnet_mhi0, checking QMI connection..."
        sudo /home/dan7554/qmi-connection-manager.sh status || true
    fi
    
    # Add default route via cellular with lower metric than WiFi
    echo "🛤️ Configuring routing table..."
    
    # Remove any existing default routes via rmnet_mhi0
    sudo ip route del default dev rmnet_mhi0 >/dev/null 2>&1 || true
    
    # Get the gateway from QMI if available, otherwise use a generic gateway
    # For Verizon, the gateway is typically the cellular carrier's gateway
    CELLULAR_GATEWAY="10.0.0.1"  # Fallback gateway
    
    # Add cellular default route with metric 100 (higher priority than WiFi's 600)
    echo "🌐 Adding default route via cellular..."
    sudo ip route add default via $CELLULAR_GATEWAY dev rmnet_mhi0 metric 100 || true
    
    echo "📊 Updated routing table:"
    ip route show
    
    echo "🔧 Testing cellular connectivity..."
    if ping -c 2 -I rmnet_mhi0 8.8.8.8 >/dev/null 2>&1; then
        echo "✅ Cellular connectivity working"
        return 0
    else
        echo "❌ Cellular connectivity test failed"
        return 1
    fi
}

# Function to configure NetworkManager for cellular priority
configure_networkmanager() {
    echo "🔧 Configuring NetworkManager for cellular priority..."
    
    # Create NetworkManager connection for cellular
    sudo nmcli connection delete "Cellular" >/dev/null 2>&1 || true
    
    sudo nmcli connection add \
        type generic \
        ifname rmnet_mhi0 \
        con-name "Cellular" \
        connection.autoconnect yes \
        connection.autoconnect-priority 10
    
    echo "✅ NetworkManager cellular connection configured"
}

# Function to restart Tailscale after routing changes
restart_tailscale() {
    echo "🔄 Restarting Tailscale..."
    sudo systemctl restart tailscale
    sleep 5
    
    echo "📊 Tailscale status:"
    sudo tailscale status || true
}

# Main execution
main() {
    echo "🚀 Starting cellular routing configuration..."
    
    # Configure routing
    if configure_cellular_routing; then
        echo "✅ Cellular routing configured"
    else
        echo "❌ Cellular routing failed"
        exit 1
    fi
    
    # Configure NetworkManager
    configure_networkmanager
    
    # Restart Tailscale
    restart_tailscale
    
    echo "🎉 Cellular routing fix complete!"
    echo ""
    echo "📋 Next steps:"
    echo "   1. Test: ping 8.8.8.8"
    echo "   2. Test Tailscale: sudo tailscale ping [peer]"
    echo "   3. Disconnect WiFi: sudo nmcli connection down [wifi-name]"
    echo ""
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    echo "⚠️ Please run without sudo (script will prompt for sudo when needed)"
    exit 1
fi

# Run main function
main "$@"