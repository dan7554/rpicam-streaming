#!/bin/bash
# SIM8262A-M2 Hardware Diagnostic Script
# Checks power, hardware connection, and troubleshooting for the 5G module

echo "🔧 SIM8262A-M2 Hardware Diagnostic Tool"
echo "========================================"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script should be run as root for complete diagnostics (use sudo)"
   echo "Will run limited diagnostics..."
   echo ""
fi

echo "📋 System Information:"
echo "Date: $(date)"
echo "Kernel: $(uname -r)"
echo "Architecture: $(uname -m)"
echo ""

# Check power supply
echo "⚡ Power Supply Check:"
echo "Current power supply voltage:"
if [ -f /sys/class/hwmon/hwmon0/in0_input ]; then
    VOLTAGE=$(cat /sys/class/hwmon/hwmon0/in0_input)
    if command -v bc >/dev/null 2>&1; then
        VOLTAGE_V=$(echo "scale=2; $VOLTAGE / 1000000" | bc 2>/dev/null || echo "Unknown")
        echo "  System voltage: ${VOLTAGE_V}V"
        if (( $(echo "$VOLTAGE_V < 4.8" | bc -l 2>/dev/null || echo 0) )); then
            echo "  ⚠️  WARNING: Voltage appears low for 5G module operation"
        fi
    else
        echo "  Raw voltage: $VOLTAGE (bc calculator not available for conversion)"
    fi
else
    echo "  Voltage monitoring not available"
fi

# Check throttling
echo ""
echo "🌡️  Thermal and Power Status:"
if command -v vcgencmd >/dev/null 2>&1; then
    THROTTLED=$(vcgencmd get_throttled)
    echo "  Throttling status: $THROTTLED"
    if [[ "$THROTTLED" != "throttled=0x0" ]]; then
        echo "  ⚠️  System has been throttled - may affect 5G module"
    fi
    
    VOLTS=$(vcgencmd measure_volts)
    echo "  Core voltage: $VOLTS"
    
    TEMP=$(vcgencmd measure_temp)
    echo "  Temperature: $TEMP"
fi

echo ""
echo "🔌 PCIe Device Detection (SIM8262A-M2 via PCIe):"
echo "All PCIe devices:"
if command -v lspci >/dev/null 2>&1; then
    lspci
    
    echo ""
    echo "📱 Cellular/Modem PCIe Devices specifically:"
    CELLULAR_PCIE=$(lspci | grep -i -E "(modem|wireless|network|qualcomm|simcom)" || echo "None found")
    if [[ "$CELLULAR_PCIE" == "None found" ]]; then
        echo "❌ No cellular PCIe devices detected"
    else
        echo "✅ Cellular PCIe device(s) found:"
        echo "$CELLULAR_PCIE"
    fi
    
    echo ""
    echo "🔍 QMI/MBIM Control Interfaces:"
    if ls /dev/cdc-wdm* 2>/dev/null; then
        echo "✅ Control interfaces found:"
        ls -la /dev/cdc-wdm*
    else
        echo "❌ No QMI/MBIM interfaces found"
    fi
    
    echo ""
    echo "🌐 WWAN Network Interfaces:"
    if ip link show | grep -q wwan; then
        echo "✅ WWAN interfaces found:"
        ip link show | grep wwan
    else
        echo "❌ No WWAN interfaces found"
    fi
else
    echo "❌ lspci command not available"
fi

echo ""
echo "🔌 USB Device Detection (for comparison):"
echo "All USB devices:"
lsusb

echo ""
echo "📱 SIMCom Devices (PCIe and USB check):"
# Check PCIe first for SIM8262A-M2
CELLULAR_PCIE=$(lspci 2>/dev/null | grep -i -E "(simcom|qualcomm)" || true)
SIMCOM_USB=$(lsusb | grep -i -E "(1e0e|simcom)" || true)

if [ ! -z "$CELLULAR_PCIE" ]; then
    echo "✅ SIMCom/Cellular PCIe device found:"
    echo "$CELLULAR_PCIE"
elif [ ! -z "$SIMCOM_USB" ]; then
    echo "✅ SIMCom USB device found:"
    echo "$SIMCOM_USB"
else
    echo "❌ No SIMCom devices detected via PCIe or USB"
    echo ""
    echo "🔧 Possible causes for PCIe-connected SIM8262A-M2:"
    echo "   1. Insufficient power - SIM8262A needs 5V 5A (25W)"
    echo "   2. M.2 PCIe connector not properly seated"
    echo "   3. PCIe not enabled in RPi5 config"
    echo "   4. SIM card preventing proper startup"
    echo "   5. Module requires specific PCIe configuration"
    echo "   6. Defective module or incompatible M.2 slot"
    echo ""
    echo "📋 PCIe-specific troubleshooting:"
    echo "   - Check /boot/config.txt for 'dtparam=pciex1'"
    echo "   - Run: dmesg | grep -i pci"
    echo "   - Verify M.2 Key-B PCIe slot compatibility"
fi

echo ""
echo "🔍 Kernel Messages (PCIe and USB related):"
echo "Recent PCIe messages:"
dmesg | grep -i pci | tail -5
echo ""
echo "Recent USB messages:"
dmesg | grep -i usb | tail -5

echo ""
echo "📦 M.2/PCIe Device Detection:"
if command -v lspci >/dev/null 2>&1; then
    echo "PCIe devices:"
    lspci | grep -i -E "(modem|wireless|network)" || echo "No relevant PCIe devices found"
else
    echo "lspci not available"
fi

echo ""
echo "🔧 GPIO Status (if applicable):"
if [ -d /sys/class/gpio ]; then
    echo "GPIO exports:"
    ls /sys/class/gpio/ | grep gpio || echo "No GPIOs exported"
else
    echo "GPIO interface not available"
fi

echo ""
echo "📊 ModemManager Status:"
if systemctl is-active --quiet ModemManager; then
    echo "✅ ModemManager is running"
    
    echo "Detected modems:"
    mmcli -L 2>/dev/null || echo "No modems detected by ModemManager"
    
    echo ""
    echo "ModemManager logs (last 10 lines):"
    journalctl -u ModemManager -n 10 --no-pager 2>/dev/null || echo "Cannot access journal"
else
    echo "❌ ModemManager is not running"
fi

echo ""
echo "💡 Troubleshooting Recommendations:"
echo ""
if [[ -z "$CELLULAR_PCIE" && -z "$SIMCOM_USB" ]]; then
    echo "🔴 CRITICAL: No cellular device detected via PCIe or USB"
    echo "For PCIe-connected SIM8262A-M2:"
    echo "   1. Check power supply: Use 5V 5A power adapter"
    echo "   2. Verify M.2 PCIe connection: Reseat the module"
    echo "   3. Enable PCIe in /boot/config.txt: Add 'dtparam=pciex1'"
    echo "   4. Check PCIe enumeration: dmesg | grep -i pci"
    echo "   5. Try without SIM card first"
    echo "   6. Check antenna connections"
    echo "   7. Power cycle the Raspberry Pi"
    echo ""
    echo "   If red LED is on but no PCIe detection:"
    echo "   - This indicates power but module not enumerating"
    echo "   - Upgrade to higher capacity power supply"
    echo "   - Check PCIe slot compatibility (Key-B required)"
    echo "   - Verify /boot/config.txt PCIe settings"
fi

echo "📋 Next Steps:"
echo "   1. If no PCIe device: Fix power/PCIe configuration first"
echo "   2. If PCIe device found: Run configure-5g-modem.sh"
echo "   3. Monitor PCIe: watch -n 1 'lspci | grep -i cellular'"
echo "   4. Debug PCIe: dmesg -w (watch for new messages)"
echo "   5. Check config: cat /boot/config.txt | grep pci"

echo ""
echo "✅ Diagnostic complete. Check the output above for issues."