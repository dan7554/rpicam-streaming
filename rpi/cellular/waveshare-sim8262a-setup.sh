#!/bin/bash
# Waveshare SIM8262A-M2 5G HAT+ Setup Script
# Based on official Waveshare documentation
# https://www.waveshare.com/wiki/SIM8262A-M2_5G_HAT%2B

set -e

echo "🌊 Waveshare SIM8262A-M2 5G HAT+ Setup"
echo "======================================"
echo "Based on Waveshare official documentation"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (use sudo)"
   exit 1
fi

# Display DIP switch requirements
echo "⚙️  IMPORTANT: DIP Switch Configuration"
echo "======================================"
echo "Before proceeding, ensure DIP switches are set correctly:"
echo "🔄 RST: OPEN (ON position)"
echo "🔋 PWR: CLOSED (OFF position)"
echo ""
read -p "Have you configured the DIP switches correctly? (y/N): " dip_confirmed
if [[ ! $dip_confirmed =~ ^[Yy]$ ]]; then
    echo "Please configure DIP switches first and run this script again."
    exit 1
fi

# Offer Waveshare kernel update
echo ""
echo "🔧 Waveshare Kernel Update"
echo "========================="
echo "Waveshare provides an optimized kernel for the SIM8262A-M2 module."
echo "This kernel includes specific drivers and optimizations."
echo ""
read -p "Do you want to install Waveshare's optimized kernel? (Y/n): " install_kernel

if [[ ! $install_kernel =~ ^[Nn]$ ]]; then
    echo "📥 Downloading and installing Waveshare kernel..."
    wget -O - https://files.waveshare.com/wiki/PCIe-TO-5G-HAT%2B/install.sh | bash
    echo "✅ Kernel installation completed"
    echo "⚠️  System will reboot automatically"
    exit 0
else
    echo "⚠️  Skipping kernel update - you may experience compatibility issues"
fi

# Update package list
echo ""
echo "📦 Updating system packages..."
apt-get update

# Install required packages
echo "📡 Installing required packages..."
apt-get install -y \
    modemmanager \
    network-manager \
    pciutils \
    minicom \
    screen \
    wget \
    curl \
    python3-pip \
    python3-gpiozero \
    python3-smbus \
    i2c-tools

# Install power monitoring tools for INA219 chip
echo "⚡ Installing power monitoring dependencies..."
echo "Trying system package first..."
if apt-get install -y python3-adafruit-circuitpython-ina219 2>/dev/null; then
    echo "✅ Installed via apt package manager"
else
    echo "📦 System package not available, installing via pip with --break-system-packages"
    pip3 install adafruit-circuitpython-ina219 --break-system-packages
fi

# Download and install Waveshare connection manager
echo "📥 Installing Waveshare connection manager..."
cd /tmp
if wget -q https://files.waveshare.com/wiki/PCIe-TO-5G-HAT%2B/Waveshare-CM.zip; then
    unzip -q Waveshare-CM.zip
    if [ -f "waveshare-CM" ]; then
        cp waveshare-CM /usr/local/bin/
        chmod +x /usr/local/bin/waveshare-CM
        echo "✅ Waveshare connection manager installed"
    else
        echo "⚠️  Waveshare-CM binary not found in archive"
    fi
else
    echo "⚠️  Could not download Waveshare-CM, will use standard tools"
fi

# Download power monitoring demo
echo "📥 Installing power monitoring demo..."
if wget -q https://files.waveshare.com/wiki/PCIe-TO-5G-HAT%2B/PCIe_TO_M.2_HAT%2B.zip; then
    unzip -q PCIe_TO_M.2_HAT+.zip -d /opt/waveshare/
    echo "✅ Power monitoring demo installed to /opt/waveshare/"
else
    echo "⚠️  Could not download power monitoring demo"
fi

cd - > /dev/null

# Create GPIO control script for module power/reset
echo "🔌 Creating GPIO control script..."
cat > /usr/local/bin/sim8262a-gpio-control.py << 'EOF'
#!/usr/bin/env python3
"""
SIM8262A-M2 GPIO Control Script
Controls module power and reset via GPIO pins 5 and 6
Based on Waveshare documentation
"""
import subprocess
import time
import sys
from gpiozero import LED

def reset_module():
    """Reset the SIM8262A module via GPIO"""
    print("🔄 Resetting SIM8262A module...")
    rst_pin = LED(5)  # GPIO5 for reset control
    rst_pin.on()
    time.sleep(0.5)
    rst_pin.off()
    print("✅ Reset signal sent")

def power_cycle_module():
    """Power cycle the SIM8262A module via GPIO"""
    print("🔋 Power cycling SIM8262A module...")
    pwr_pin = LED(6)  # GPIO6 for power control
    pwr_pin.on()
    time.sleep(1)
    pwr_pin.off()
    time.sleep(2)
    pwr_pin.on()
    print("✅ Power cycle completed")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: sim8262a-gpio-control.py {reset|power}")
        sys.exit(1)
    
    action = sys.argv[1]
    if action == "reset":
        reset_module()
    elif action == "power":
        power_cycle_module()
    else:
        print("Invalid action. Use 'reset' or 'power'")
        sys.exit(1)
EOF

chmod +x /usr/local/bin/sim8262a-gpio-control.py

# Create driver reload script (Waveshare recommendation)
echo "🔄 Creating PCIe driver reload script..."
cat > /usr/local/bin/reload-pcie-drivers.sh << 'EOF'
#!/bin/bash
# Waveshare recommended PCIe driver reload sequence
echo "🔄 Reloading PCIe MHI drivers (Waveshare sequence)..."
sudo rmmod pcie_mhi 2>/dev/null || true
sleep 30
sudo modprobe pcie_mhi
echo "✅ PCIe driver reload completed"

# Check if module is detected
echo "🔍 Checking PCIe device detection..."
lspci | grep -i -E "(modem|wireless|network|qualcomm|simcom)" || echo "No cellular devices found"

# Check for control interfaces
echo "🔍 Checking for control interfaces..."
ls /dev/cdc-wdm* 2>/dev/null || echo "No QMI/MBIM interfaces found"
EOF

chmod +x /usr/local/bin/reload-pcie-drivers.sh

# Create power monitoring script
echo "⚡ Creating power monitoring script..."
cat > /usr/local/bin/sim8262a-power-monitor.py << 'EOF'
#!/usr/bin/env python3
"""
SIM8262A Power Monitoring using INA219
Monitors voltage and current consumption
"""
try:
    import board
    import busio
    import adafruit_ina219
    import time
    
    i2c = busio.I2C(board.SCL, board.SDA)
    ina219 = adafruit_ina219.INA219(i2c, addr=0x40)  # Default address
    
    print("⚡ SIM8262A Power Monitoring")
    print("==========================")
    print("Press Ctrl+C to stop")
    print()
    
    while True:
        bus_voltage = ina219.bus_voltage
        shunt_voltage = ina219.shunt_voltage
        current = ina219.current
        power = ina219.power
        
        print(f"Bus Voltage:   {bus_voltage:.2f} V")
        print(f"Shunt Voltage: {shunt_voltage:.2f} mV")
        print(f"Current:       {current:.2f} mA")
        print(f"Power:         {power:.2f} mW")
        print("-" * 30)
        
        time.sleep(2)
        
except ImportError:
    print("❌ INA219 library not installed.")
    print("💡 Try installing with:")
    print("   sudo apt install python3-adafruit-circuitpython-ina219")
    print("   OR: pip3 install adafruit-circuitpython-ina219 --break-system-packages")
except Exception as e:
    print(f"❌ Power monitoring error: {e}")
EOF

chmod +x /usr/local/bin/sim8262a-power-monitor.py

# Enable I2C for power monitoring
echo "🔧 Enabling I2C interface..."
if ! grep -q "^dtparam=i2c_arm=on" /boot/config.txt; then
    echo "dtparam=i2c_arm=on" >> /boot/config.txt
    echo "✅ I2C enabled in config.txt"
fi

# Enable and start ModemManager
echo "📡 Configuring ModemManager..."
systemctl enable ModemManager
systemctl start ModemManager

# Check PCIe device detection
echo ""
echo "🔍 Checking PCIe device detection..."
if lspci | grep -i -E "(modem|wireless|network|qualcomm|simcom)"; then
    echo "✅ Cellular PCIe device detected"
else
    echo "⚠️  No cellular PCIe devices found"
    echo "📋 All PCIe devices:"
    lspci
fi

# Final status and instructions
echo ""
echo "🎉 Waveshare SIM8262A-M2 Setup Complete!"
echo "========================================"
echo ""
echo "📋 Available Commands:"
echo "• sudo waveshare-CM                     - Waveshare connection manager"
echo "• sudo /usr/local/bin/reload-pcie-drivers.sh - Reload PCIe drivers"
echo "• python3 /usr/local/bin/sim8262a-gpio-control.py reset - Reset module"
echo "• python3 /usr/local/bin/sim8262a-gpio-control.py power - Power cycle"
echo "• python3 /usr/local/bin/sim8262a-power-monitor.py      - Monitor power"
echo ""
echo "📋 Next Steps:"
echo "1. Reboot the system: sudo reboot"
echo "2. After reboot, check detection: lspci"
echo "3. Reload drivers if needed: sudo /usr/local/bin/reload-pcie-drivers.sh"
echo "4. Use Waveshare connection manager: sudo waveshare-CM"
echo "5. Or use standard setup: ./setup-cellular-connection.sh"
echo ""
echo "🔧 Troubleshooting:"
echo "• Check DIP switches: RST=OPEN, PWR=CLOSED"
echo "• Monitor power: python3 /usr/local/bin/sim8262a-power-monitor.py"
echo "• Reset module: python3 /usr/local/bin/sim8262a-gpio-control.py reset"
echo "• Check logs: journalctl -u ModemManager -f"
echo ""
echo "📖 Documentation: https://www.waveshare.com/wiki/SIM8262A-M2_5G_HAT%2B"