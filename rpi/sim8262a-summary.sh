#!/bin/bash
# SIM8262A-M2 Quick Setup and Management Summary
# Provides an overview and quick access to all scripts

echo "📱 SIM8262A-M2 5G Module Management"
echo "==================================="
echo ""

# Check if we're in the right directory
if [ ! -f "configure-5g-modem.sh" ]; then
    echo "❌ Please run this script from the rpi directory"
    exit 1
fi

echo "📋 Available Scripts:"
echo ""
echo "0️⃣  PCIe Configuration (run first):"
echo "   sudo ./enable-pcie.sh      - Enable PCIe interface (REBOOT REQUIRED)"
echo ""
echo "1️⃣  Hardware Diagnostics:"
echo "   ./sim8262a-diagnostic.sh   - Check power, PCIe detection, system health"
echo ""
echo "2️⃣  Initial Setup (after PCIe enabled):"
echo "   sudo ./configure-5g-modem.sh - Install software and configure modem"
echo ""
echo "3️⃣  Carrier Configuration:"
echo "   sudo ./setup-cellular-connection.sh - Setup Verizon or eiotclub connection"
echo ""
echo "4️⃣  Daily Management:"
echo "   sudo ./carrier-switcher.sh - Interactive carrier switching"
echo "   ./modem-manager.sh [check|connect|disconnect|status]"
echo ""
echo "📖 Documentation:"
echo "   README-SIM8262A.md - Complete setup guide"
echo ""

# Quick status check
echo "🔍 Quick System Status:"
echo ""

# Check PCIe configuration first
echo "🔌 PCIe Configuration:"
if [ -f "/boot/config.txt" ]; then
    if grep -q "dtparam=pciex1" /boot/config.txt 2>/dev/null; then
        echo "✅ PCIe enabled in boot config"
    else
        echo "❌ PCIe not enabled - run sudo ./enable-pcie.sh first"
    fi
else
    echo "⚠️  Cannot check boot configuration"
fi

# Check for PCIe devices
if command -v lspci >/dev/null 2>&1; then
    PCIE_CELLULAR=$(lspci 2>/dev/null | grep -i -E "(modem|wireless|network|qualcomm|simcom)" || true)
    if [ ! -z "$PCIE_CELLULAR" ]; then
        echo "✅ PCIe cellular device detected"
    else
        echo "❌ No PCIe cellular devices found"
    fi
else
    if lsusb | grep -q "1e0e"; then
        echo "⚠️  SIMCom device found via USB (should be PCIe)"
    else
        echo "❌ No cellular devices found - check power and connections"
    fi
fi

# Check if ModemManager is running
if systemctl is-active --quiet ModemManager 2>/dev/null; then
    echo "✅ ModemManager service is running"
    
    # Check for modems
    MODEM_COUNT=$(mmcli -L 2>/dev/null | grep -c "Modem" || echo "0")
    if [ "$MODEM_COUNT" -gt 0 ]; then
        echo "✅ $MODEM_COUNT modem(s) detected by ModemManager"
    else
        echo "⚠️  ModemManager running but no modems detected"
    fi
else
    echo "❌ ModemManager service not running"
fi

# Check for cellular connections
CELLULAR_CONNECTIONS=$(nmcli connection show 2>/dev/null | grep gsm | wc -l || echo "0")
if [ "$CELLULAR_CONNECTIONS" -gt 0 ]; then
    echo "✅ $CELLULAR_CONNECTIONS cellular connection(s) configured"
    
    # Check for active connections
    ACTIVE_CONNECTIONS=$(nmcli connection show --active 2>/dev/null | grep gsm | wc -l || echo "0")
    if [ "$ACTIVE_CONNECTIONS" -gt 0 ]; then
        echo "✅ $ACTIVE_CONNECTIONS cellular connection(s) active"
    else
        echo "⚠️  Cellular connections configured but none active"
    fi
else
    echo "❌ No cellular connections configured"
fi

echo ""
echo "💡 Quick Start Guide:"
echo ""
echo "First time setup:"
echo "0. sudo ./enable-pcie.sh             # Enable PCIe (reboot required)"
echo "1. sudo ./sim8262a-diagnostic.sh     # Check hardware after reboot"
echo "2. sudo ./configure-5g-modem.sh      # Configure modem"
echo "3. sudo ./setup-cellular-connection.sh # Setup carrier"
echo ""
echo "Daily usage:"
echo "4. sudo ./carrier-switcher.sh         # Switch carriers or manage connections"
echo ""

# Check for common issues
echo "🔧 Common Issues Check:"
echo ""

# Power supply check
if [ -f /sys/class/hwmon/hwmon0/in0_input ]; then
    VOLTAGE=$(cat /sys/class/hwmon/hwmon0/in0_input)
    if command -v bc >/dev/null 2>&1; then
        VOLTAGE_V=$(echo "scale=2; $VOLTAGE / 1000000" | bc 2>/dev/null)
        if (( $(echo "$VOLTAGE_V < 4.8" | bc -l 2>/dev/null || echo 0) )); then
            echo "⚠️  Low voltage detected - consider upgrading power supply"
        fi
    fi
fi

# Check for throttling
if command -v vcgencmd >/dev/null 2>&1; then
    THROTTLED=$(vcgencmd get_throttled)
    if [[ "$THROTTLED" != "throttled=0x0" ]]; then
        echo "⚠️  System throttling detected - may affect 5G performance"
    fi
fi

echo "✅ Status check complete"