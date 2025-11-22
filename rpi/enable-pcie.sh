#!/bin/bash
# Raspberry Pi 5 PCIe Configuration Script for SIM8262A-M2
# Enables and configures PCIe interface for cellular modules

set -e

echo "🔧 Configuring Raspberry Pi 5 PCIe for SIM8262A-M2"
echo "=================================================="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (use sudo)"
   exit 1
fi

# Check if we're on Raspberry Pi 5
PI_MODEL=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' || echo "Unknown")
echo "📋 Detected device: $PI_MODEL"

if [[ "$PI_MODEL" != *"Raspberry Pi 5"* ]]; then
    echo "⚠️  Warning: This script is designed for Raspberry Pi 5"
    echo "PCIe configuration may differ on other models"
fi

# Backup current config.txt
echo "💾 Backing up current boot configuration..."
cp /boot/config.txt /boot/config.txt.backup.$(date +%Y%m%d_%H%M%S)

# Check current PCIe configuration
echo "🔍 Checking current PCIe configuration..."
CURRENT_PCIE=$(grep -E "^dtparam=pciex1" /boot/config.txt || true)
CURRENT_PCIE_GEN=$(grep -E "^dtparam=pciex1_gen" /boot/config.txt || true)

if [ -n "$CURRENT_PCIE" ]; then
    echo "✅ PCIe already enabled: $CURRENT_PCIE"
else
    echo "📝 PCIe not currently enabled in config.txt"
fi

# Configure PCIe settings for SIM8262A-M2
echo "🔧 Configuring PCIe for SIM8262A-M2..."

# Remove any existing PCIe settings to avoid conflicts
sed -i '/^dtparam=pciex1/d' /boot/config.txt
sed -i '/^dtparam=pciex1_gen/d' /boot/config.txt

# Add optimized PCIe configuration for cellular module
echo "" >> /boot/config.txt
echo "# PCIe Configuration for SIM8262A-M2 Cellular Module" >> /boot/config.txt
echo "# Enable PCIe x1 slot" >> /boot/config.txt
echo "dtparam=pciex1" >> /boot/config.txt
echo "" >> /boot/config.txt
echo "# Set PCIe generation for compatibility (Gen 2 is safer for cellular modules)" >> /boot/config.txt
echo "dtparam=pciex1_gen=2" >> /boot/config.txt
echo "" >> /boot/config.txt

# Additional power and stability settings
echo "⚡ Adding power and stability configurations..."
echo "# Power and stability settings for 5G module" >> /boot/config.txt
echo "# Increase GPU memory split (helps with PCIe stability)" >> /boot/config.txt
echo "gpu_mem=128" >> /boot/config.txt
echo "" >> /boot/config.txt
echo "# USB current limit increase (for overall power stability)" >> /boot/config.txt
echo "max_usb_current=1" >> /boot/config.txt
echo "" >> /boot/config.txt

# Check for firmware updates
echo "🔄 Checking firmware version..."
FIRMWARE_VERSION=$(vcgencmd version | head -n1)
echo "Current firmware: $FIRMWARE_VERSION"

# Check if raspi-config is available for PCIe
if command -v raspi-config >/dev/null 2>&1; then
    echo "🛠️  raspi-config available - PCIe can also be enabled via raspi-config"
else
    echo "⚠️  raspi-config not available"
fi

# Show current PCIe status
echo "📊 Current PCIe Configuration Summary:"
echo "Config file: /boot/config.txt"
grep -A 10 -B 2 "PCIe Configuration" /boot/config.txt || echo "Configuration added"

# Check for existing PCIe devices
echo "🔍 Checking for existing PCIe devices..."
if command -v lspci >/dev/null 2>&1; then
    PCIE_DEVICES=$(lspci 2>/dev/null || echo "No devices found")
    echo "Current PCIe devices:"
    echo "$PCIE_DEVICES"
else
    echo "lspci not available - will be installed with configure-5g-modem.sh"
fi

# Create PCIe diagnostic script
echo "📝 Creating PCIe diagnostic script..."
cat > /usr/local/bin/check-pcie-config << 'EOF'
#!/bin/bash
# PCIe Configuration Checker for Raspberry Pi 5

echo "=== PCIe Configuration Check ==="
echo "Date: $(date)"
echo ""

echo "📋 Boot Configuration:"
echo "PCIe enabled:"
grep "dtparam=pciex1" /boot/config.txt || echo "  Not configured"
echo "PCIe generation:"
grep "dtparam=pciex1_gen" /boot/config.txt || echo "  Default (auto)"

echo ""
echo "🔌 PCIe Devices:"
if command -v lspci >/dev/null 2>&1; then
    lspci || echo "No PCIe devices detected"
else
    echo "lspci not installed"
fi

echo ""
echo "🔋 Power Status:"
if command -v vcgencmd >/dev/null 2>&1; then
    echo "Throttling: $(vcgencmd get_throttled)"
    echo "Temperature: $(vcgencmd measure_temp)"
    echo "Voltage: $(vcgencmd measure_volts)"
else
    echo "vcgencmd not available"
fi

echo ""
echo "📊 Kernel PCIe Messages:"
dmesg | grep -i pci | tail -5 || echo "No PCIe messages found"
EOF

chmod +x /usr/local/bin/check-pcie-config

echo ""
echo "✅ PCIe configuration complete!"
echo ""
echo "🔄 IMPORTANT: Reboot required for PCIe changes to take effect"
echo ""
echo "📋 Next steps:"
echo "1. Reboot the Raspberry Pi: sudo reboot"
echo "2. After reboot, check PCIe: sudo /usr/local/bin/check-pcie-config"
echo "3. Install your SIM8262A-M2 module (if not already installed)"
echo "4. Run cellular configuration: sudo ./configure-5g-modem.sh"
echo ""
echo "🔍 Verification commands after reboot:"
echo "   - Check PCIe devices: lspci"
echo "   - Check config: cat /boot/config.txt | grep pcie"
echo "   - Check kernel messages: dmesg | grep -i pci"
echo ""

read -p "🔄 Would you like to reboot now? [y/N]: " reboot_now
if [[ $reboot_now =~ ^[Yy]$ ]]; then
    echo "🔄 Rebooting in 5 seconds..."
    sleep 5
    reboot
else
    echo "👍 Remember to reboot before using the SIM8262A-M2 module"
fi