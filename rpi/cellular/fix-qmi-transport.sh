#!/bin/bash
# Fix QMI transport detection for SIM8262A-M2 MHI device
# Addresses "Cannot automatically select QMI/MBIM mode" errors

set -e

echo "🔧 QMI Transport Fix for SIM8262A-M2"
echo "====================================="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (use sudo)"
   exit 1
fi

# Function to test QMI with explicit device type
test_qmi_with_explicit_mode() {
    local mode=$1
    echo "🔍 Testing QMI with explicit $mode mode..."
    
    # Try with explicit device type
    timeout 30 qmicli -d /dev/mhi_QMI0 --device-open-$mode --device-open-version-info 2>&1 || {
        echo "⚠️ $mode mode failed"
        return 1
    }
}

# Function to fix QMI device permissions and setup
fix_qmi_device() {
    echo "🔧 Fixing QMI device setup..."
    
    # Set proper permissions
    chmod 666 /dev/mhi_QMI0 2>/dev/null || echo "Could not change permissions"
    
    # Check device exists and is accessible
    if [ ! -e /dev/mhi_QMI0 ]; then
        echo "❌ QMI device /dev/mhi_QMI0 not found"
        echo "Checking for alternative QMI devices..."
        find /dev -name "*QMI*" -o -name "*qmi*" -o -name "*WWAN*" -o -name "*wwan*" 2>/dev/null || echo "No QMI devices found"
        return 1
    fi
    
    echo "✅ QMI device found: /dev/mhi_QMI0"
    ls -la /dev/mhi_QMI0
}

# Function to test QMI connection with proper flags
test_qmi_connection() {
    echo "🌐 Testing QMI connection with fixed transport..."
    
    # Try QMI mode first (most common for SIM8262A)
    echo "Testing with QMI mode explicitly..."
    if timeout 30 qmicli -d /dev/mhi_QMI0 --device-open-qmi --device-open-version-info >/dev/null 2>&1; then
        echo "✅ QMI mode working!"
        QMI_MODE="qmi"
    elif timeout 30 qmicli -d /dev/mhi_QMI0 --device-open-mbim --device-open-version-info >/dev/null 2>&1; then
        echo "✅ MBIM mode working!"
        QMI_MODE="mbim"
    else
        echo "❌ Neither QMI nor MBIM mode working"
        echo "Trying alternative approach..."
        
        # Try without explicit mode (let it auto-detect but with different flags)
        if timeout 30 qmicli -d /dev/mhi_QMI0 --device-open-version-info >/dev/null 2>&1; then
            echo "✅ Auto-detection working!"
            QMI_MODE="auto"
        else
            echo "❌ All QMI modes failed"
            return 1
        fi
    fi
    
    echo "Using QMI mode: $QMI_MODE"
    return 0
}

# Function to test network connection with fixed QMI
test_network_with_fixed_qmi() {
    local apn=$1
    echo "🔗 Testing network connection with APN: $apn"
    
    case $QMI_MODE in
        "qmi")
            timeout 60 qmicli -d /dev/mhi_QMI0 --device-open-qmi --wds-start-network="apn='$apn'" --client-no-release-cid
            ;;
        "mbim")
            timeout 60 qmicli -d /dev/mhi_QMI0 --device-open-mbim --wds-start-network="apn='$apn'" --client-no-release-cid
            ;;
        "auto")
            timeout 60 qmicli -d /dev/mhi_QMI0 --wds-start-network="apn='$apn'" --client-no-release-cid
            ;;
        *)
            echo "❌ Unknown QMI mode"
            return 1
            ;;
    esac
}

# Function to restart services that might interfere
restart_services() {
    echo "🔄 Restarting cellular services..."
    
    # Stop ModemManager temporarily
    systemctl stop ModemManager 2>/dev/null || echo "ModemManager not running"
    sleep 2
    
    # Restart ModemManager
    systemctl start ModemManager
    sleep 5
    
    # Check if ModemManager detects the modem
    echo "Waiting for ModemManager to detect modem..."
    for i in {1..10}; do
        if mmcli -L 2>/dev/null | grep -q "Modem"; then
            echo "✅ ModemManager detected modem"
            break
        fi
        echo "Waiting... ($i/10)"
        sleep 3
    done
}

# Function to check MHI driver status
check_mhi_status() {
    echo "🔍 Checking MHI driver status..."
    
    # Check if MHI drivers are loaded
    if lsmod | grep -q mhi; then
        echo "✅ MHI drivers loaded:"
        lsmod | grep mhi
    else
        echo "❌ MHI drivers not loaded"
        echo "Loading MHI drivers..."
        modprobe mhi || echo "Could not load MHI module"
    fi
    
    # Check MHI devices
    echo "MHI devices:"
    ls -la /dev/mhi_* 2>/dev/null || echo "No MHI devices found"
    
    # Check if rmnet interface exists
    if ip link show rmnet_mhi0 >/dev/null 2>&1; then
        echo "✅ rmnet_mhi0 interface exists"
        ip link show rmnet_mhi0
    else
        echo "⚠️ rmnet_mhi0 interface not found"
    fi
}

# Main execution
echo "🚀 Starting QMI transport fix..."

# Check MHI status first
check_mhi_status
echo ""

# Fix QMI device
fix_qmi_device
echo ""

# Restart services
restart_services
echo ""

# Test QMI connection
if test_qmi_connection; then
    echo ""
    echo "✅ QMI transport fixed! Testing with Mint Mobile APNs..."
    
    # Test different Mint Mobile APNs
    for apn in "wholesale" "Ultra" "Mint" "fast.t-mobile.com" "wholesale.truphone.com"; do
        echo ""
        echo "🔸 Testing APN: $apn"
        
        if test_network_with_fixed_qmi "$apn"; then
            echo "✅ Success with APN: $apn"
            
            # Try to configure interface
            echo "Configuring network interface..."
            ip link set rmnet_mhi0 up
            timeout 10 dhclient rmnet_mhi0 &
            sleep 8
            
            # Check if we got an IP
            if ip addr show rmnet_mhi0 | grep -q "inet.*[0-9]"; then
                ASSIGNED_IP=$(ip addr show rmnet_mhi0 | grep "inet " | awk '{print $2}')
                echo "✅ Got cellular IP: $ASSIGNED_IP"
                
                # Test internet connectivity
                if ping -c 3 8.8.8.8 >/dev/null 2>&1; then
                    echo "🌐 Internet connectivity successful!"
                    echo "🎉 Mint Mobile connection working with APN: $apn"
                    break
                else
                    echo "⚠️ No internet connectivity yet"
                fi
            else
                echo "⚠️ No IP assigned"
            fi
        else
            echo "❌ Failed with APN: $apn"
        fi
    done
    
else
    echo "❌ Could not fix QMI transport"
    echo ""
    echo "🔧 Manual troubleshooting steps:"
    echo "1. Check hardware connection"
    echo "2. Verify PCIe is enabled: cat /boot/firmware/config.txt | grep pcie"
    echo "3. Restart system: sudo reboot"
    echo "4. Check dmesg for MHI errors: dmesg | grep -i mhi"
fi

echo ""
echo "📊 Final Status:"
echo "==============="
echo "QMI Device: $([ -e /dev/mhi_QMI0 ] && echo 'Present' || echo 'Missing')"
echo "MHI Drivers: $(lsmod | grep -q mhi && echo 'Loaded' || echo 'Not Loaded')"
echo "rmnet Interface: $(ip link show rmnet_mhi0 >/dev/null 2>&1 && echo 'Present' || echo 'Missing')"

if ip addr show rmnet_mhi0 2>/dev/null | grep -q "inet.*[0-9]"; then
    CURRENT_IP=$(ip addr show rmnet_mhi0 | grep "inet " | awk '{print $2}')
    echo "Current IP: $CURRENT_IP"
    
    # Check if it's a real cellular IP or fallback
    if [[ $CURRENT_IP =~ ^192\.168\. ]] || [[ $CURRENT_IP =~ ^10\. ]] || [[ $CURRENT_IP =~ ^172\. ]]; then
        echo "⚠️ IP appears to be local/fallback - no real cellular connection"
    else
        echo "✅ IP appears to be real cellular IP"
    fi
else
    echo "Current IP: None assigned"
fi