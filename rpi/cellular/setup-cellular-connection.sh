#!/bin/bash
# 5G Connection Setup Script
# Creates a NetworkManager connection for Verizon or eiotclub SIM cards

set -e

echo "📡 Setting up 5G Cellular Connection"
echo "===================================="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (use sudo)"
   exit 1
fi

# Function to display carrier menu
select_carrier() {
    echo ""
    echo "📱 Select your SIM card carrier:"
    echo "1) Verizon"
    echo "2) eiotclub"
    echo "3) Mint Mobile"
    echo "4) Exit"
    echo ""
    read -p "Enter choice [1-4]: " choice
    
    case $choice in
        1)
            CARRIER="verizon"
            APN="vzwinternet"
            CONNECTION_NAME="Verizon5G"
            USERNAME=""
            PASSWORD=""
            echo "✅ Selected: Verizon"
            ;;
        2)
            CARRIER="eiotclub"
            APN="iot.1nce.net"
            CONNECTION_NAME="eiotclub5G"
            USERNAME=""
            PASSWORD=""
            echo "✅ Selected: eiotclub"
            echo "ℹ️  Note: Using iot.1nce.net APN (verify with your provider)"
            ;;
        3)
            CARRIER="mintmobile"
            APN="wholesale"
            CONNECTION_NAME="MintMobile5G"
            USERNAME=""
            PASSWORD=""
            echo "✅ Selected: Mint Mobile"
            echo "ℹ️  Note: Using T-Mobile wholesale network"
            ;;
        4)
            echo "👋 Exiting..."
            exit 0
            ;;
        *)
            echo "❌ Invalid choice. Please try again."
            select_carrier
            ;;
    esac
}

# Select carrier
select_carrier

# Verify modem is detected before proceeding
echo "🔍 Checking for modem availability..."
MODEM_COUNT=$(mmcli -L 2>/dev/null | grep -c "Modem" || echo "0")

if [ "$MODEM_COUNT" -eq 0 ]; then
    echo "❌ No modem detected. Please run configure-5g-modem.sh first."
    echo "💡 If the modem was just configured, wait a few minutes for initialization."
    echo "💡 Try: sudo systemctl restart ModemManager && sleep 30"
    exit 1
fi

echo "✅ Found $MODEM_COUNT modem(s)"

# Get modem path
MODEM=$(mmcli -L | grep -o "/org/freedesktop/ModemManager1/Modem/[0-9]*" | head -n1)
if [ -n "$MODEM" ]; then
    echo "📱 Using modem: $MODEM"
    
    # Check SIM status
    echo "🔍 Checking SIM card status..."
    SIM_STATUS=$(mmcli -m $MODEM --sim=0 2>/dev/null | grep -i "state" || echo "SIM status unknown")
    echo "SIM Status: $SIM_STATUS"
fi

# Check if connection already exists
if nmcli connection show "$CONNECTION_NAME" > /dev/null 2>&1; then
    echo "✅ Connection '$CONNECTION_NAME' already exists."
    read -p "🔄 Do you want to recreate it? [y/N]: " recreate
    if [[ $recreate =~ ^[Yy]$ ]]; then
        echo "🗑️  Removing existing connection..."
        nmcli connection delete "$CONNECTION_NAME"
    else
        echo "✅ Keeping existing connection. Exiting."
        exit 0
    fi
fi
echo "📝 Creating NetworkManager connection for $CARRIER with SIM8262A-M2 optimizations..."
nmcli connection add \
    type gsm \
    ifname "*" \
    con-name "$CONNECTION_NAME" \
    gsm.apn "$APN" \
    gsm.username "$USERNAME" \
    gsm.password "$PASSWORD" \
    connection.autoconnect yes \
    connection.autoconnect-priority 100 \
    connection.autoconnect-retries 0 \
    ipv4.method auto \
    ipv6.method auto

# Additional settings for SIM8262A-M2 5G optimization
echo "🔧 Configuring advanced settings for 5G performance..."
nmcli connection modify "$CONNECTION_NAME" \
    connection.autoconnect-retries 0

echo "✅ $CARRIER connection '$CONNECTION_NAME' created with SIM8262A optimizations."

# Display carrier-specific information
case $CARRIER in
    "verizon")
        echo ""
        echo "📋 Verizon Configuration:"
        echo "   APN: $APN"
        echo "   Network: LTE/5G"
        echo "   Authentication: None"
        ;;
    "eiotclub")
        echo ""
        echo "📋 eiotclub Configuration:"
        echo "   APN: $APN"
        echo "   Network: LTE/5G"
        echo "   Authentication: None"
        echo "   Note: eiotclub typically provides M2M/IoT connectivity"
        ;;
    "mintmobile")
        echo ""
        echo "📋 Mint Mobile Configuration:"
        echo "   APN: $APN"
        echo "   Network: T-Mobile LTE/5G"
        echo "   Authentication: None"
        echo "   Note: Mint Mobile uses T-Mobile's wholesale network"
        ;;
esac

echo ""
echo "💡 Connection will auto-connect when the modem is ready."
echo ""
echo "🔍 Current connections:"
nmcli connection show

echo ""
echo "📱 To manually connect:"
echo "   sudo nmcli connection up $CONNECTION_NAME"
echo ""
echo "📊 To check status:"
echo "   nmcli connection show $CONNECTION_NAME"
echo "   nmcli device status"
echo ""
echo "🌐 To test connectivity:"
echo "   ping -c 4 8.8.8.8"
