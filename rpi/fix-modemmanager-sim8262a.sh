#!/bin/bash
# ModemManager configuration fix for SIM8262A-M2 (Device ID 0308)
# This script configures ModemManager to recognize the Waveshare SIM8262A-M2

set -e

echo "🔧 ModemManager Fix for SIM8262A-M2"
echo "===================================="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (use sudo)"
   exit 1
fi

# Function to create ModemManager udev rules for SIM8262A-M2
create_udev_rules() {
    echo "📝 Creating udev rules for SIM8262A-M2..."
    
    # Create udev rule file for the SIM8262A-M2
    cat > /etc/udev/rules.d/77-sim8262a-modem.rules << 'EOF'
# SIM8262A-M2 5G Module - Waveshare
# PCI Device ID: 17cb:0308
# Force ModemManager to recognize this device

# Match the specific Qualcomm device ID for SIM8262A-M2
SUBSYSTEM=="net", ATTRS{device}=="0x0308", ATTRS{vendor}=="0x17cb", ENV{ID_MM_DEVICE_MANUAL_SCAN_ONLY}="1"
SUBSYSTEM=="net", KERNEL=="rmnet_mhi*", ENV{ID_MM_DEVICE_MANUAL_SCAN_ONLY}="1"

# Tag MHI QMI devices for ModemManager
SUBSYSTEM=="usbmisc", KERNEL=="mhi_QMI*", TAG+="systemd", ENV{SYSTEMD_WANTS}="ModemManager.service"
KERNEL=="mhi_QMI*", SUBSYSTEM=="misc", TAG+="systemd", ENV{SYSTEMD_WANTS}="ModemManager.service"

# Set permissions for MHI devices
KERNEL=="mhi_QMI*", MODE="0666", GROUP="dialout"
KERNEL=="mhi_DIAG*", MODE="0666", GROUP="dialout"
KERNEL=="mhi_DUN*", MODE="0666", GROUP="dialout"

# Additional rules for rmnet interface
SUBSYSTEM=="net", KERNEL=="rmnet_mhi*", TAG+="systemd"
EOF

    echo "✅ Created udev rules: /etc/udev/rules.d/77-sim8262a-modem.rules"
}

# Function to create ModemManager filter configuration
create_mm_filter() {
    echo "📝 Creating ModemManager filter configuration..."
    
    # Create ModemManager configuration directory if it doesn't exist
    mkdir -p /etc/ModemManager/fcc-unlock.d
    
    # Create a configuration file for SIM8262A-M2
    cat > /etc/ModemManager/connection.d/sim8262a.conf << 'EOF'
# Configuration for SIM8262A-M2 5G Module
[connection]
allowed-drivers=qmi_wwan,cdc_mbim,qcserial
forbidden-drivers=
EOF

    echo "✅ Created ModemManager config: /etc/ModemManager/connection.d/sim8262a.conf"
}

# Function to add device to ModemManager whitelist
add_device_whitelist() {
    echo "📝 Adding SIM8262A-M2 to ModemManager device database..."
    
    # Check if we can modify the ModemManager database
    MM_DIR="/usr/share/ModemManager"
    if [ -d "$MM_DIR" ]; then
        # Look for device database files
        find $MM_DIR -name "*.rules" -o -name "*.conf" | head -5
    fi
    
    # Create a custom plugin configuration
    mkdir -p /etc/ModemManager/fcc-unlock.d
    
    cat > /etc/ModemManager/fcc-unlock.d/sim8262a.json << 'EOF'
{
    "name": "SIM8262A-M2",
    "vid": "0x17cb",
    "pid": "0x0308",
    "rules": [
        {
            "type": "at",
            "delay": 3000,
            "commands": [
                "AT+CFUN=1"
            ]
        }
    ]
}
EOF
}

# Function to restart services and reload rules
restart_services() {
    echo "🔄 Restarting services and reloading udev rules..."
    
    # Reload udev rules
    udevadm control --reload-rules
    udevadm trigger
    
    # Restart ModemManager with more verbose logging
    systemctl stop ModemManager
    sleep 3
    
    # Start ModemManager with debug logging
    echo "🔍 Starting ModemManager with debug logging..."
    systemctl start ModemManager
    sleep 5
}

# Function to test if ModemManager detects the modem
test_detection() {
    echo "🔍 Testing ModemManager detection..."
    
    # Wait a bit for detection
    for i in {1..15}; do
        MODEMS=$(mmcli -L 2>/dev/null | grep "Modem" | wc -l || echo "0")
        if [ "$MODEMS" -gt 0 ]; then
            echo "✅ ModemManager detected $MODEMS modem(s)!"
            mmcli -L
            return 0
        fi
        echo "Waiting for detection... ($i/15)"
        sleep 2
    done
    
    echo "❌ ModemManager still not detecting modem"
    return 1
}

# Function to manually probe the device
manual_device_probe() {
    echo "🔧 Attempting manual device probe..."
    
    # Check if we can force ModemManager to scan specific device
    if [ -e /dev/mhi_QMI0 ]; then
        echo "Found QMI device, attempting manual probe..."
        
        # Try to manually trigger ModemManager scan
        udevadm trigger --subsystem-match=misc --property-match=DEVNAME=/dev/mhi_QMI0
        sleep 3
        
        # Try alternative approach - restart with specific device path
        systemctl stop ModemManager
        
        # Start ModemManager with explicit device
        echo "Starting ModemManager with manual device specification..."
        ModemManager --debug 2>&1 | head -20 &
        MM_PID=$!
        sleep 10
        kill $MM_PID 2>/dev/null || true
        
        systemctl start ModemManager
        sleep 5
    fi
}

# Function to create alternative connection method
create_direct_qmi_method() {
    echo "🔧 Creating direct QMI connection method..."
    
    cat > /home/dan7554/direct-qmi-connect.sh << 'EOF'
#!/bin/bash
# Direct QMI connection for SIM8262A-M2 bypassing ModemManager

echo "🔗 Direct QMI Connection for SIM8262A-M2"
echo "========================================"

# Stop ModemManager to avoid conflicts
systemctl stop ModemManager 2>/dev/null || true

# Bring up the interface
ip link set rmnet_mhi0 up

# Use qmi-network instead of qmicli directly
echo "Using qmi-network for connection management..."

# Create profile for qmi-network
cat > /tmp/qmi-network.profile << 'PROFILE'
APN=wholesale
APN_USER=
APN_PASS=
PROFILE

# Start network with qmi-network
echo "Starting network with qmi-network..."
qmi-network /dev/mhi_QMI0 start

# Check status
echo "Connection status:"
qmi-network /dev/mhi_QMI0 status

# Get IP settings if connection successful
if qmi-network /dev/mhi_QMI0 status | grep -q "Connected"; then
    echo "✅ QMI connection successful!"
    
    # Configure interface with DHCP
    echo "Configuring interface..."
    dhclient rmnet_mhi0 &
    sleep 10
    
    # Show final status
    echo "Interface status:"
    ip addr show rmnet_mhi0
    
    echo "Testing connectivity:"
    ping -c 3 8.8.8.8
else
    echo "❌ QMI connection failed"
fi
EOF
    
    chmod +x /home/dan7554/direct-qmi-connect.sh
    echo "✅ Created direct QMI connection script: /home/dan7554/direct-qmi-connect.sh"
}

# Main execution
echo "🚀 Starting ModemManager fix for SIM8262A-M2..."

# Create udev rules
create_udev_rules

# Create MM filter
create_mm_filter

# Add to whitelist
add_device_whitelist

# Create direct connection method as backup
create_direct_qmi_method

# Restart services
restart_services

# Test detection
if test_detection; then
    echo ""
    echo "🎉 SUCCESS! ModemManager now detects the SIM8262A-M2!"
    echo ""
    echo "Next steps:"
    echo "1. Try: sudo nmcli connection up MintMobile5G"
    echo "2. Or run: sudo ./test-mintmobile-sim.sh"
else
    echo ""
    echo "⚠️  ModemManager still not detecting. Trying manual probe..."
    manual_device_probe
    
    if test_detection; then
        echo "🎉 Manual probe successful!"
    else
        echo "❌ ModemManager detection failed. Using direct QMI method:"
        echo ""
        echo "🔧 Alternative solution:"
        echo "Run: sudo ./direct-qmi-connect.sh"
        echo ""
        echo "This bypasses ModemManager and connects directly via QMI."
    fi
fi

echo ""
echo "📊 Final Status:"
echo "================"
echo "Udev rules: ✅ Created"
echo "MM config: ✅ Created"
echo "Direct QMI script: ✅ Available"
echo ""
echo "Device Info:"
lspci | grep Qualcomm
echo "MHI devices:"
ls -la /dev/mhi_* 2>/dev/null || echo "No MHI devices"
echo "ModemManager detection:"
mmcli -L 2>/dev/null || echo "No modems detected by ModemManager"