#!/bin/bash
# Advanced QMI transport fix for SIM8262A-M2 with explicit mode detection
# This script handles the transport detection issue by trying different approaches

set -e

echo "🔬 Advanced QMI Transport Fix for SIM8262A-M2"
echo "=============================================="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (use sudo)"
   exit 1
fi

# Function to test raw device access
test_raw_device() {
    echo "🔍 Testing raw device access..."
    
    if [ ! -e /dev/mhi_QMI0 ]; then
        echo "❌ QMI device not found"
        return 1
    fi
    
    # Check device permissions
    echo "Device permissions:"
    ls -la /dev/mhi_QMI0
    
    # Test if device is readable/writable
    if timeout 5 dd if=/dev/mhi_QMI0 of=/dev/null bs=1 count=1 2>/dev/null; then
        echo "✅ Device is accessible"
    else
        echo "⚠️ Device access test failed"
    fi
}

# Function to create custom QMI service
create_qmi_service() {
    echo "📝 Creating custom QMI service for SIM8262A-M2..."
    
    cat > /etc/systemd/system/sim8262a-qmi.service << 'EOF'
[Unit]
Description=SIM8262A-M2 QMI Connection Service
After=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/home/dan7554/qmi-connection-manager.sh start
ExecStop=/home/dan7554/qmi-connection-manager.sh stop
TimeoutStartSec=60
Restart=no

[Install]
WantedBy=multi-user.target
EOF

    echo "✅ Created systemd service: /etc/systemd/system/sim8262a-qmi.service"
}

# Function to create advanced QMI connection manager
create_qmi_manager() {
    echo "📝 Creating advanced QMI connection manager..."
    
    cat > /home/dan7554/qmi-connection-manager.sh << 'EOF'
#!/bin/bash
# Advanced QMI Connection Manager for SIM8262A-M2
# Handles transport detection and connection management

QMI_DEVICE="/dev/mhi_QMI0"
INTERFACE="rmnet_mhi0"
APN="wholesale"  # Mint Mobile APN

# Function to detect QMI transport mode
detect_transport_mode() {
    echo "🔍 Detecting QMI transport mode..."
    
    # Method 1: Try QMI mode with explicit proxy
    if timeout 10 qmicli -d "$QMI_DEVICE" --device-open-qmi --device-open-proxy --dms-get-manufacturer 2>/dev/null | grep -q "Manufacturer"; then
        echo "✅ QMI mode with proxy detected"
        export QMI_MODE="qmi-proxy"
        return 0
    fi
    
    # Method 2: Try QMI mode without proxy
    if timeout 10 qmicli -d "$QMI_DEVICE" --device-open-qmi --dms-get-manufacturer 2>/dev/null | grep -q "Manufacturer"; then
        echo "✅ QMI mode detected"
        export QMI_MODE="qmi"
        return 0
    fi
    
    # Method 3: Try MBIM mode
    if timeout 10 qmicli -d "$QMI_DEVICE" --device-open-mbim --dms-get-manufacturer 2>/dev/null | grep -q "Manufacturer"; then
        echo "✅ MBIM mode detected"
        export QMI_MODE="mbim"
        return 0
    fi
    
    # Method 4: Try with explicit transport type
    if timeout 10 qmicli -d "$QMI_DEVICE" --device-open-net=net-raw-ip --dms-get-manufacturer 2>/dev/null | grep -q "Manufacturer"; then
        echo "✅ Raw IP mode detected"
        export QMI_MODE="raw-ip"
        return 0
    fi
    
    echo "❌ Could not detect transport mode"
    return 1
}

# Function to start QMI connection
start_connection() {
    echo "🚀 Starting QMI connection..."
    
    # Ensure interface is up
    ip link set "$INTERFACE" up
    
    case $QMI_MODE in
        "qmi-proxy")
            echo "Using QMI mode with proxy..."
            qmicli -d "$QMI_DEVICE" --device-open-qmi --device-open-proxy --wds-start-network="apn='$APN'" --client-no-release-cid
            ;;
        "qmi")
            echo "Using QMI mode..."
            qmicli -d "$QMI_DEVICE" --device-open-qmi --wds-start-network="apn='$APN'" --client-no-release-cid
            ;;
        "mbim")
            echo "Using MBIM mode..."
            qmicli -d "$QMI_DEVICE" --device-open-mbim --wds-start-network="apn='$APN'" --client-no-release-cid
            ;;
        "raw-ip")
            echo "Using Raw IP mode..."
            qmicli -d "$QMI_DEVICE" --device-open-net=net-raw-ip --wds-start-network="apn='$APN'" --client-no-release-cid
            ;;
        *)
            echo "❌ Unknown transport mode"
            return 1
            ;;
    esac
    
    # Wait for connection
    sleep 5
    
    # Configure interface with DHCP
    echo "Configuring interface with DHCP..."
    timeout 30 dhclient "$INTERFACE" || {
        echo "DHCP failed, trying manual configuration..."
        # Try to get IP settings from QMI
        get_ip_from_qmi
    }
}

# Function to get IP configuration from QMI
get_ip_from_qmi() {
    echo "🔧 Getting IP configuration from QMI..."
    
    case $QMI_MODE in
        "qmi-proxy")
            IP_INFO=$(qmicli -d "$QMI_DEVICE" --device-open-qmi --device-open-proxy --wds-get-current-settings)
            ;;
        "qmi")
            IP_INFO=$(qmicli -d "$QMI_DEVICE" --device-open-qmi --wds-get-current-settings)
            ;;
        "mbim")
            IP_INFO=$(qmicli -d "$QMI_DEVICE" --device-open-mbim --wds-get-current-settings)
            ;;
        "raw-ip")
            IP_INFO=$(qmicli -d "$QMI_DEVICE" --device-open-net=net-raw-ip --wds-get-current-settings)
            ;;
    esac
    
    echo "QMI IP Info: $IP_INFO"
    
    # Parse IP settings (simplified)
    if echo "$IP_INFO" | grep -q "IPv4 address"; then
        echo "✅ Got IPv4 settings from QMI"
    else
        echo "⚠️ Using fallback IP configuration"
        # Set a test IP to verify interface works
        ip addr add 10.0.0.100/24 dev "$INTERFACE" || true
    fi
}

# Function to stop connection
stop_connection() {
    echo "🛑 Stopping QMI connection..."
    
    # Kill any DHCP clients
    pkill dhclient || true
    
    # Bring down interface
    ip link set "$INTERFACE" down || true
    
    # Stop QMI connection (if we had a handle)
    case $QMI_MODE in
        "qmi-proxy"|"qmi")
            qmicli -d "$QMI_DEVICE" --device-open-qmi --wds-stop-network || true
            ;;
        "mbim")
            qmicli -d "$QMI_DEVICE" --device-open-mbim --wds-stop-network || true
            ;;
        "raw-ip")
            qmicli -d "$QMI_DEVICE" --device-open-net=net-raw-ip --wds-stop-network || true
            ;;
    esac
    
    echo "✅ Connection stopped"
}

# Function to check status
check_status() {
    echo "📊 QMI Connection Status:"
    echo "========================"
    
    # Interface status
    echo "Interface Status:"
    ip addr show "$INTERFACE" 2>/dev/null || echo "Interface not found"
    
    # QMI status
    if [ -n "$QMI_MODE" ]; then
        echo "Transport Mode: $QMI_MODE"
        
        case $QMI_MODE in
            "qmi-proxy")
                qmicli -d "$QMI_DEVICE" --device-open-qmi --device-open-proxy --wds-get-packet-service-status || true
                ;;
            "qmi")
                qmicli -d "$QMI_DEVICE" --device-open-qmi --wds-get-packet-service-status || true
                ;;
            "mbim")
                qmicli -d "$QMI_DEVICE" --device-open-mbim --wds-get-packet-service-status || true
                ;;
        esac
    fi
    
    # Test connectivity
    echo "Connectivity Test:"
    if ping -c 3 8.8.8.8 >/dev/null 2>&1; then
        echo "✅ Internet connectivity working"
        echo "Public IP: $(curl -s ifconfig.me 2>/dev/null || echo 'Unknown')"
    else
        echo "❌ No internet connectivity"
    fi
}

# Main execution
case "${1:-status}" in
    start)
        echo "🚀 Starting SIM8262A-M2 connection..."
        if detect_transport_mode; then
            start_connection
            check_status
        else
            echo "❌ Could not detect transport mode"
            exit 1
        fi
        ;;
    stop)
        stop_connection
        ;;
    status)
        check_status
        ;;
    detect)
        detect_transport_mode
        echo "Detected mode: ${QMI_MODE:-unknown}"
        ;;
    *)
        echo "Usage: $0 {start|stop|status|detect}"
        echo ""
        echo "Commands:"
        echo "  start   - Start QMI connection"
        echo "  stop    - Stop QMI connection"
        echo "  status  - Show connection status"
        echo "  detect  - Detect transport mode"
        exit 1
        ;;
esac
EOF

    chmod +x /home/dan7554/qmi-connection-manager.sh
    echo "✅ Created QMI connection manager: /home/dan7554/qmi-connection-manager.sh"
}

# Function to try alternative libqmi approach
try_alternative_libqmi() {
    echo "🔧 Trying alternative libqmi approach..."
    
    # Check if qmi-proxy is running
    if pgrep qmi-proxy >/dev/null; then
        echo "qmi-proxy is running, stopping it..."
        pkill qmi-proxy || true
        sleep 2
    fi
    
    # Try starting qmi-proxy explicitly
    echo "Starting qmi-proxy..."
    qmi-proxy &
    sleep 3
    
    # Test with proxy
    echo "Testing with qmi-proxy..."
    if timeout 10 qmicli -d /dev/mhi_QMI0 --device-open-qmi --device-open-proxy --device-open-version-info 2>/dev/null; then
        echo "✅ qmi-proxy approach working!"
        return 0
    else
        echo "❌ qmi-proxy approach failed"
        pkill qmi-proxy || true
        return 1
    fi
}

# Main execution
echo "🚀 Starting advanced QMI transport fix..."

# Test raw device access
test_raw_device

# Create custom service and manager
create_qmi_service
create_qmi_manager

# Try alternative approaches
echo ""
echo "🔧 Testing alternative QMI approaches..."

# Try alternative libqmi method
if try_alternative_libqmi; then
    echo "✅ Alternative libqmi method successful!"
else
    echo "⚠️ Alternative methods failed, using custom manager..."
fi

# Test the custom manager
echo ""
echo "🧪 Testing custom QMI connection manager..."
/home/dan7554/qmi-connection-manager.sh detect

# Enable the service
systemctl daemon-reload
systemctl enable sim8262a-qmi.service

echo ""
echo "📊 Setup Complete!"
echo "=================="
echo "✅ Custom QMI manager created"
echo "✅ Systemd service configured"
echo "✅ Alternative transport methods tested"
echo ""
echo "🚀 To start connection:"
echo "   sudo /home/dan7554/qmi-connection-manager.sh start"
echo ""
echo "📊 To check status:"
echo "   sudo /home/dan7554/qmi-connection-manager.sh status"
echo ""
echo "🛑 To stop connection:"
echo "   sudo /home/dan7554/qmi-connection-manager.sh stop"
echo ""
echo "🔄 To enable automatic startup:"
echo "   sudo systemctl start sim8262a-qmi.service"