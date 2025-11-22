#!/bin/bash
# Modem Management Script for SIM8262A-M2

# Function to check modem status
check_modem() {
    echo "📡 Checking modem status..."
    MODEM=$(mmcli -L 2>/dev/null | grep -o "/org/freedesktop/ModemManager1/Modem/[0-9]*" | head -n1)
    
    if [ -n "$MODEM" ]; then
        echo "✅ Modem found: $MODEM"
        
        # Get detailed status
        echo "📋 Modem Details:"
        mmcli -m $MODEM | grep -E "(State|Signal|Access tech|Operator)"
    else
        echo "❌ No modem detected."
    fi
}

# Function to connect to the network
connect() {
    echo "🌐 Available connections:"
    nmcli connection show | grep gsm
    
    echo ""
    read -p "Enter connection name to connect (or press Enter for auto-detect): " conn_name
    
    if [ -z "$conn_name" ]; then
        # Auto-detect available cellular connections
        CELLULAR_CONN=$(nmcli connection show | grep gsm | head -n1 | awk '{print $1}')
        if [ -n "$CELLULAR_CONN" ]; then
            echo "🔍 Auto-detected connection: $CELLULAR_CONN"
            conn_name="$CELLULAR_CONN"
        else
            echo "❌ No cellular connections found. Run setup-cellular-connection.sh first."
            return 1
        fi
    fi
    
    echo "🌐 Attempting to connect to: $conn_name"
    nmcli connection up "$conn_name"
}

# Function to disconnect from the network
disconnect() {
    echo "🔌 Available active connections:"
    nmcli connection show --active | grep gsm
    
    echo ""
    read -p "Enter connection name to disconnect (or press Enter for auto-detect): " conn_name
    
    if [ -z "$conn_name" ]; then
        # Auto-detect active cellular connections
        ACTIVE_CONN=$(nmcli connection show --active | grep gsm | head -n1 | awk '{print $1}')
        if [ -n "$ACTIVE_CONN" ]; then
            echo "🔍 Auto-detected active connection: $ACTIVE_CONN"
            conn_name="$ACTIVE_CONN"
        else
            echo "❌ No active cellular connections found."
            return 1
        fi
    fi
    
    echo "🔌 Disconnecting from: $conn_name"
    nmcli connection down "$conn_name"
}

# Function to display connection status
status() {
    echo "📊 All Cellular Connections:"
    nmcli connection show | grep gsm || echo "No cellular connections configured"
    
    echo ""
    echo "📶 Active Connections:"
    nmcli connection show --active | grep gsm || echo "No active cellular connections"
    
    echo ""
    echo "� Device Status:"
    nmcli device status | grep -E "(gsm|wwan)" || echo "No cellular devices found"
    
    echo ""
    echo "🌐 Network Interfaces:"
    ip addr show | grep -A 5 -E "(wwan|ppp)" || echo "No cellular interfaces active"
}

# Main script logic
case "$1" in
    check)
        check_modem
        ;;
    connect)
        connect
        ;;
    disconnect)
        disconnect
        ;;
    status)
        status
        ;;
    *)
        echo "Usage: $0 {check|connect|disconnect|status}"
        exit 1
esac
