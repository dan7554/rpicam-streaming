#!/bin/bash
# SIM8262A-M2 5G Module Configuration Script for Raspberry Pi 5
# Configures the 5G module for use with multiple carriers

set -e

echo "🔧 Configuring SIM8262A-M2 5G Module for Multiple Carriers"
echo "==========================================================="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (use sudo)"
   exit 1
fi

# Update system packages
echo "📦 Updating system packages..."
apt update

# Install required packages for PCIe cellular modem
echo "📡 Installing ModemManager and dependencies..."
apt install -y modemmanager network-manager minicom screen ppp wvdial libqmi-utils

# Install additional utilities and PCIe tools
echo "🛠️  Installing additional utilities..."
apt install -y curl wget jq pciutils

# Enable and start ModemManager
echo "🚀 Enabling ModemManager service..."
systemctl enable ModemManager
systemctl start ModemManager

# Wait for services to start
echo "⏳ Waiting for services to initialize..."
sleep 5

# Check for USB mode switch rules for SIM8262A-M2
echo "🔄 Checking SIM8262A-M2 PCIe configuration..."

# Since SIM8262A-M2 is connected via PCIe, no USB mode switching needed
echo "📝 Configuring for PCIe-connected SIM8262A-M2..."

# Check if PCIe device is detected
echo "🔍 Checking PCIe devices..."
if command -v lspci >/dev/null 2>&1; then
    PCIE_DEVICES=$(lspci | grep -i -E "(modem|wireless|network|qualcomm|simcom)" || true)
    if [ ! -z "$PCIE_DEVICES" ]; then
        echo "✅ PCIe device(s) detected:"
        echo "$PCIE_DEVICES"
    else
        echo "⚠️  No relevant PCIe devices found"
        echo "📋 All PCIe devices:"
        lspci
    fi
else
    echo "❌ lspci command not available"
fi

# Check for QMI/MBIM interfaces (common for PCIe cellular modules)
echo "� Checking for QMI/MBIM interfaces..."
if ls /dev/cdc-wdm* 2>/dev/null; then
    echo "✅ QMI/MBIM interfaces found:"
    ls -la /dev/cdc-wdm*
else
    echo "⚠️  No QMI/MBIM interfaces found yet"
fi

# Check for WWAN network interfaces
echo "🌐 Checking for WWAN interfaces..."
if ip link show | grep -q wwan; then
    echo "✅ WWAN interfaces found:"
    ip link show | grep wwan
else
    echo "⚠️  No WWAN interfaces found yet"
fi

# Check for SIM8262A device with comprehensive detection (PCIe)
echo "🔍 Checking for PCIe-connected SIM8262A device..."
echo "⚠️  IMPORTANT: SIM8262A-M2 requires adequate power supply!"
echo "   Red LED indicates the module is powered but may need more current"
echo "   Recommended: 5V 5A power supply for stable operation"
echo ""

# Check for PCIe cellular devices first
PCIE_CELLULAR=$(lspci 2>/dev/null | grep -i -E "(modem|wireless|network|qualcomm|simcom)" || true)
if [ ! -z "$PCIE_CELLULAR" ]; then
    echo "✅ PCIe cellular device(s) detected:"
    echo "$PCIE_CELLULAR"
    
    # Check for specific SIMCom or Qualcomm devices
    if lspci | grep -i -q "simcom\|qualcomm"; then
        echo "📱 SIM8262A or compatible device found via PCIe"
    else
        echo "📱 Generic cellular PCIe device detected"
    fi
    
    # Check for QMI/MBIM control interfaces
    echo "🔍 Checking for control interfaces..."
    if ls /dev/cdc-wdm* 2>/dev/null; then
        echo "✅ QMI/MBIM control interfaces found:"
        ls -la /dev/cdc-wdm*
    else
        echo "⚠️  QMI/MBIM interfaces not yet available"
    fi
    
    # Check for WWAN network interfaces
    echo "🌐 Checking for WWAN interfaces..."
    if ip link show | grep -q wwan; then
        echo "✅ WWAN interfaces found:"
        ip link show | grep wwan
    else
        echo "⚠️  WWAN interfaces not yet available"
    fi
    
else
    echo "❌ No cellular PCIe devices detected"
    echo ""
    echo "🔧 Troubleshooting steps for PCIe connection:"
    echo "1. Check M.2 PCIe connection is secure"
    echo "2. Verify SIM card is properly inserted"
    echo "3. Ensure adequate power supply (5V 5A recommended)"
    echo "4. Check if red LED is solid (indicates power but insufficient current)"
    echo "5. Try power cycling the Raspberry Pi"
    echo "6. Check dmesg for PCIe enumeration: dmesg | grep -i pci"
    echo "7. Verify RPi5 PCIe is enabled in config.txt"
    echo ""
    echo "📋 PCIe troubleshooting:"
    echo "   - Check: /boot/config.txt should have 'dtparam=pciex1'"
    echo "   - Run: dmesg | grep -i pci"
    echo "   - List all PCIe: lspci -v"
fi

# Restart ModemManager to detect the modem
echo "🔄 Restarting ModemManager with extended timeout..."
systemctl restart ModemManager
sleep 20  # Extended wait for SIM8262A initialization

# Check for modem detection with detailed diagnostics
echo "📡 Checking for modem detection..."
echo "🔍 Running comprehensive modem detection..."

# Wait for modem to be fully initialized
for i in {1..30}; do
    MODEM_COUNT=$(mmcli -L 2>/dev/null | grep -c "Modem" || echo "0")
    if [ "$MODEM_COUNT" -gt 0 ]; then
        break
    fi
    echo "⏳ Waiting for modem initialization... ($i/30)"
    sleep 2
done

if [ "$MODEM_COUNT" -gt 0 ]; then
    echo "✅ Modem(s) detected: $MODEM_COUNT"
    
    # Get first modem
    MODEM=$(mmcli -L | grep -o "/org/freedesktop/ModemManager1/Modem/[0-9]*" | head -n1)
    
    if [ -n "$MODEM" ]; then
        echo "📋 Modem Information:"
        mmcli -m $MODEM
        
        echo ""
        echo "📱 SIM Status:"
        mmcli -m $MODEM --sim=0 2>/dev/null || echo "⚠️  SIM not detected or not ready"
        
        echo ""
        echo "🏗️  Checking modem capabilities..."
        mmcli -m $MODEM --list-bearers
        
        echo ""
        echo "📶 Signal information (if available):"
        mmcli -m $MODEM --signal-get 2>/dev/null || echo "Signal information not available yet"
    fi
else
    echo "❌ No modem detected by ModemManager after 60 seconds"
    echo ""
    echo "� Additional troubleshooting for SIM8262A-M2:"
    echo "   - Power issue: Red LED with no detection usually indicates insufficient power"
    echo "   - Required: 5V 5A power supply (25W) for stable 5G operation"
    echo "   - Check: GPIO power control may be needed for some boards"
    echo "   - Verify: M.2 Key-B connector is properly seated"
    echo "   - Test: Try without SIM card first to see if device enumerates"
    echo ""
    echo "🔍 Current USB device status:"
    lsusb | grep -i -E "(1e0e|simcom)" || echo "No SIMCom devices found in lsusb"
    echo ""
    echo "📋 Check kernel messages:"
    echo "   dmesg | tail -20"
    echo "   dmesg | grep -i usb"
fi

# Create modem monitoring script
echo "📝 Creating modem monitoring script..."
cat > /usr/local/bin/check-modem-status << 'EOF'
#!/bin/bash
# Quick modem status check for PCIe-connected SIM8262A-M2

echo "=== Modem Status Check ==="
echo "Date: $(date)"
echo ""

echo "📡 ModemManager Status:"
systemctl is-active ModemManager

echo ""
echo "📱 Detected Modems:"
mmcli -L 2>/dev/null || echo "No modems detected"

echo ""
echo "🔌 PCIe Cellular Devices:"
lspci | grep -i -E "(modem|wireless|network|qualcomm|simcom)" || echo "No cellular PCIe devices found"

echo ""
echo "🌐 Network Interfaces:"
ip addr show | grep -E "(wwan|ppp)" || echo "No cellular interfaces found"

echo ""
echo "📊 NetworkManager Connections:"
nmcli connection show | grep gsm || echo "No GSM connections configured"

echo ""
echo "🔍 QMI/MBIM Interfaces:"
ls -la /dev/cdc-wdm* 2>/dev/null || echo "No QMI/MBIM interfaces found"
EOF

chmod +x /usr/local/bin/check-modem-status

echo ""
echo "✅ SIM8262A-M2 5G Module configuration complete!"
echo ""
echo "📋 Next steps:"
echo "   1. Run: sudo /usr/local/bin/check-modem-status"
echo "   2. Configure carrier connection: sudo ./setup-cellular-connection.sh"
echo "   3. Monitor logs: journalctl -u ModemManager -f"
echo ""
echo "🔍 Troubleshooting commands:"
echo "   - Check PCIe devices: lspci | grep -i -E 'modem|wireless|qualcomm|simcom'"
echo "   - Check QMI interfaces: ls -la /dev/cdc-wdm*"
echo "   - List modems: mmcli -L"
echo "   - Modem info: mmcli -m 0"
echo "   - SIM status: mmcli -m 0 --sim=0"
echo "   - Check WWAN: ip link show | grep wwan"