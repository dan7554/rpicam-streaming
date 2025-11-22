#!/bin/bash
# Test script for Mint Mobile SIM card connectivity
# Comprehensive testing for Mint Mobile (T-Mobile MVNO) network

set -e

echo "🟢 Mint Mobile SIM Testing Tool"
echo "=============================="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (use sudo)"
   exit 1
fi

# Mint Mobile Configuration
CARRIER="mintmobile"
APN="wholesale"
CONNECTION_NAME="MintMobile5G"

echo "📱 Testing Mint Mobile SIM Configuration"
echo "Carrier: $CARRIER"
echo "APN: $APN"
echo "Network: T-Mobile (MVNO)"
echo ""

# Function to test QMI connection with Mint Mobile settings
test_qmi_connection() {
    echo "🔧 Testing QMI Direct Connection for Mint Mobile..."
    
    if [ -e /dev/mhi_QMI0 ]; then
        echo "✅ QMI device found: /dev/mhi_QMI0"
        
        # Test basic QMI communication
        echo "📡 Testing QMI communication..."
        timeout 30 qmicli -d /dev/mhi_QMI0 --device-open-version-info || echo "⚠️ QMI version check failed"
        
        # Get network registration for T-Mobile
        echo "📶 Checking T-Mobile network registration..."
        NAS_STATUS=$(timeout 30 qmicli -d /dev/mhi_QMI0 --nas-get-serving-system 2>/dev/null || echo "Failed")
        echo "Network Status: $NAS_STATUS"
        
        # Attempt direct connection with T-Mobile settings
        echo "🌐 Attempting QMI connection with Mint Mobile APN..."
        
        # Start network with T-Mobile optimized settings
        echo "Starting network interface..."
        timeout 60 qmicli -d /dev/mhi_QMI0 --wds-start-network="apn='$APN'" --client-no-release-cid || {
            echo "⚠️ Direct QMI connection attempt failed"
            echo "💡 This may be normal - trying alternative method..."
        }
        
        # Alternative connection method for T-Mobile MVNOs
        echo "🔄 Trying alternative T-Mobile MVNO connection..."
        timeout 60 qmicli -d /dev/mhi_QMI0 --wds-start-network="apn='$APN',ip-type=4" --client-no-release-cid || {
            echo "⚠️ Alternative connection also failed"
        }
        
    else
        echo "❌ QMI device not found at /dev/mhi_QMI0"
        echo "💡 Try running: sudo systemctl restart ModemManager"
        return 1
    fi
}

# Function to test NetworkManager with Mint Mobile
test_networkmanager() {
    echo "🔧 Testing NetworkManager with Mint Mobile..."
    
    # Check if connection exists
    if nmcli connection show "$CONNECTION_NAME" > /dev/null 2>&1; then
        echo "✅ Found existing $CONNECTION_NAME connection"
        
        # Show connection details
        echo "📋 Connection details:"
        nmcli connection show "$CONNECTION_NAME" | grep -E "(gsm\.|connection\.|ipv4\.)" | head -10
        
        # Test connection
        echo "🌐 Testing connection activation..."
        nmcli connection down "$CONNECTION_NAME" 2>/dev/null || true
        sleep 5
        
        timeout 60 nmcli connection up "$CONNECTION_NAME" || {
            echo "⚠️ NetworkManager connection failed"
            echo "📊 Checking detailed error info..."
            nmcli connection show "$CONNECTION_NAME" | grep -i error || true
        }
        
        # Check if interface is up
        INTERFACE=$(nmcli connection show "$CONNECTION_NAME" | grep connection.interface-name | awk '{print $2}')
        if [ -n "$INTERFACE" ] && [ "$INTERFACE" != "--" ]; then
            echo "✅ Interface assigned: $INTERFACE"
            ip addr show "$INTERFACE" 2>/dev/null | head -5 || true
        fi
        
    else
        echo "❌ $CONNECTION_NAME connection not found"
        echo "💡 Run setup-cellular-connection.sh first and select Mint Mobile"
        return 1
    fi
}

# Function to test T-Mobile specific connectivity
test_tmobile_connectivity() {
    echo "🔧 Testing T-Mobile Network Connectivity..."
    
    # Check for any cellular interface
    CELLULAR_INTERFACE=$(ip link show | grep -E "(rmnet|wwan|ppp)" | head -1 | awk -F: '{print $2}' | tr -d ' ' || echo "")
    
    if [ -n "$CELLULAR_INTERFACE" ]; then
        echo "✅ Found cellular interface: $CELLULAR_INTERFACE"
        
        # Check IPv4 assignment (might be fallback)
        IPV4_ADDR=$(ip addr show "$CELLULAR_INTERFACE" | grep 'inet ' | awk '{print $2}' || echo "")
        
        # Check IPv6 assignment (likely real cellular)
        IPV6_ADDR=$(ip addr show "$CELLULAR_INTERFACE" | grep 'inet6.*global' | awk '{print $2}' | head -1 || echo "")
        
        # Get QMI-provided IP info if available
        QMI_IP_INFO=""
        if [ -e /dev/mhi_QMI0 ]; then
            QMI_IP_INFO=$(timeout 10 qmicli -d /dev/mhi_QMI0 --device-open-qmi --device-open-proxy --wds-get-current-settings 2>/dev/null | grep -E "(IPv4 address|IPv6 address)" | head -2 || echo "")
        fi
        
        echo "📍 Interface IP Addresses:"
        if [ -n "$IPV6_ADDR" ]; then
            echo "   🌐 IPv6 (Cellular): $IPV6_ADDR"
            DISPLAY_IP="$IPV6_ADDR (Cellular IPv6)"
        fi
        
        if [ -n "$IPV4_ADDR" ]; then
            if [[ "$IPV4_ADDR" =~ ^10\.|^192\.168\.|^172\. ]]; then
                echo "   🔧 IPv4 (Fallback): $IPV4_ADDR"
                if [ -z "$DISPLAY_IP" ]; then
                    DISPLAY_IP="$IPV4_ADDR (Fallback)"
                fi
            else
                echo "   🌐 IPv4 (Cellular): $IPV4_ADDR"
                DISPLAY_IP="$IPV4_ADDR (Cellular IPv4)"
            fi
        fi
        
        if [ -n "$QMI_IP_INFO" ]; then
            echo "   📡 QMI Settings:"
            echo "$QMI_IP_INFO" | sed 's/^/      /'
        fi
        
        if [ -n "$DISPLAY_IP" ]; then
            echo "🌐 Testing Internet connectivity via T-Mobile..."
            
            # Test with T-Mobile DNS
            ping -c 3 -W 10 8.8.8.8 || echo "⚠️ Ping to Google DNS failed"
            ping -c 3 -W 10 208.67.222.222 || echo "⚠️ Ping to OpenDNS failed"
            
            # Test HTTP connectivity and get real public IP
            PUBLIC_IP=$(curl -s --max-time 15 http://httpbin.org/ip 2>/dev/null | grep -o '"origin": "[^"]*"' | cut -d'"' -f4 || echo "Unknown")
            if [ "$PUBLIC_IP" != "Unknown" ]; then
                echo "📍 Public IP: $PUBLIC_IP"
            else
                echo "⚠️ HTTP test failed"
            fi
        else
            echo "❌ No IP address assigned to cellular interface"
        fi
    else
        echo "❌ No cellular interface found"
    fi
}

# Function to extract Mint Mobile SIM information
extract_sim_info() {
    echo "📱 Extracting Mint Mobile SIM Information..."
    
    if [ -e /dev/mhi_QMI0 ]; then
        # Get ICCID
        echo "🔢 SIM ICCID:"
        timeout 20 qmicli -d /dev/mhi_QMI0 --uim-get-card-status 2>/dev/null | grep -i "iccid" || echo "ICCID not available"
        
        # Get IMSI
        echo "🔢 IMSI:"
        timeout 20 qmicli -d /dev/mhi_QMI0 --dms-get-ids 2>/dev/null | grep -i "imsi" || echo "IMSI not available"
        
        # Get network registration for T-Mobile
        echo "📶 T-Mobile Registration Status:"
        timeout 20 qmicli -d /dev/mhi_QMI0 --nas-get-serving-system 2>/dev/null || echo "Registration status not available"
        
        # Check for T-Mobile network
        echo "🌐 Network Operator Information:"
        timeout 20 qmicli -d /dev/mhi_QMI0 --nas-get-home-network 2>/dev/null | grep -E "(Description|MCC|MNC)" || echo "Network info not available"
        
    else
        echo "❌ QMI device not available for SIM information extraction"
    fi
}

# Main testing sequence
echo "🚀 Starting Mint Mobile SIM Tests..."
echo ""

# Extract SIM information first
extract_sim_info
echo ""

# Test QMI direct connection
test_qmi_connection
echo ""

# Test NetworkManager
test_networkmanager
echo ""

# Test connectivity
test_tmobile_connectivity
echo ""

echo "📊 Test Summary for Mint Mobile"
echo "==============================="
echo "✅ QMI Device: $([ -e /dev/mhi_QMI0 ] && echo 'Available' || echo 'Not Found')"
echo "✅ NetworkManager Connection: $(nmcli connection show "$CONNECTION_NAME" >/dev/null 2>&1 && echo 'Configured' || echo 'Missing')"

CELLULAR_IF=$(ip link show | grep -E "(rmnet|wwan|ppp)" | head -1 | awk -F: '{print $2}' | tr -d ' ' || echo "")
echo "✅ Cellular Interface: ${CELLULAR_IF:-'Not Found'}"

if [ -n "$CELLULAR_IF" ]; then
    # Get both IPv4 and IPv6 addresses
    IPV4_STATUS=$(ip addr show "$CELLULAR_IF" | grep 'inet ' | awk '{print $2}' || echo "None")
    IPV6_STATUS=$(ip addr show "$CELLULAR_IF" | grep 'inet6.*global' | awk '{print $2}' | head -1 || echo "None")
    
    # Determine primary IP to display
    if [ "$IPV6_STATUS" != "None" ]; then
        echo "✅ Primary IP: $IPV6_STATUS (Cellular IPv6)"
        if [ "$IPV4_STATUS" != "None" ]; then
            if [[ "$IPV4_STATUS" =~ ^10\.|^192\.168\.|^172\. ]]; then
                echo "✅ Fallback IP: $IPV4_STATUS (Local)"
            else
                echo "✅ IPv4 Address: $IPV4_STATUS (Cellular)"
            fi
        fi
    elif [ "$IPV4_STATUS" != "None" ]; then
        if [[ "$IPV4_STATUS" =~ ^10\.|^192\.168\.|^172\. ]]; then
            echo "✅ IP Address: $IPV4_STATUS (Fallback - No Real Cellular IP)"
        else
            echo "✅ IP Address: $IPV4_STATUS (Cellular IPv4)"
        fi
    else
        echo "❌ IP Address: None assigned"
    fi
    
    # Show connection status
    INTERFACE_STATE=$(ip link show "$CELLULAR_IF" | grep -o "state [A-Z]*" | cut -d' ' -f2)
    if [ "$INTERFACE_STATE" = "UP" ] || ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        echo "✅ Connection Status: Active"
    else
        echo "⚠️ Connection Status: Interface down but may have cellular routing"
    fi
fi

echo ""
echo "💡 Troubleshooting Tips for Mint Mobile:"
echo "   • Ensure SIM is activated with Mint Mobile"
echo "   • Verify T-Mobile coverage in your area"
echo "   • Check account status and data allowance"
echo "   • Try: sudo nmcli connection up $CONNECTION_NAME"
echo "   • For support: Contact Mint Mobile with device IMEI and SIM ICCID"
echo ""
echo "🔗 Mint Mobile Support: https://www.mintmobile.com/support/"