#!/bin/bash
# SIM8262A-M2 Module Mode Configuration
# Configures the module for PCIe EP mode or USB mode
# Based on Waveshare documentation

echo "⚙️  SIM8262A Module Mode Configuration"
echo "===================================="
echo ""
echo "This script configures the SIM8262A module operating mode:"
echo "• PCIe EP Mode: For use with Raspberry Pi via PCIe interface"
echo "• USB Mode: For direct connection to Windows PC via USB-C"
echo ""

# Check if we can find a USB-connected module for AT commands
USB_DEVICE=""
if ls /dev/ttyUSB* 2>/dev/null; then
    echo "📱 Found USB serial interfaces:"
    ls -la /dev/ttyUSB*
    echo ""
    echo "Available devices for AT commands:"
    for device in /dev/ttyUSB*; do
        echo "  $device"
    done
    echo ""
    read -p "Enter the AT command device (e.g., /dev/ttyUSB2): " USB_DEVICE
elif ls /dev/ttyACM* 2>/dev/null; then
    echo "📱 Found ACM serial interfaces:"
    ls -la /dev/ttyACM*
    echo ""
    USB_DEVICE="/dev/ttyACM0"
else
    echo "❌ No USB serial interfaces found"
    echo ""
    echo "💡 To configure module mode:"
    echo "1. Connect SIM8262A to a Windows PC via USB-C cable"
    echo "2. Install SIM8200 OS Driver from Waveshare resources"
    echo "3. Use serial port assistant to send AT commands"
    echo ""
    echo "📋 AT Commands for PCIe EP Mode:"
    echo "AT+CCUART=1"
    echo "AT+CPCIEMODE=EP"
    echo "AT+CUSBCFG=usbid,1e0e,9001"
    echo ""
    echo "📋 AT Commands for USB Mode:"
    echo "AT+CUSBCFG=usbid,1e0e,9011"
    echo ""
    exit 1
fi

echo ""
echo "📋 Configuration Options:"
echo "1. Configure for PCIe EP Mode (Raspberry Pi)"
echo "2. Configure for USB Mode (Windows PC)"
echo "3. Check current configuration"
echo ""
read -p "Select option (1-3): " mode_choice

# Function to send AT command
send_at_command() {
    local command=$1
    local device=$2
    local timeout=${3:-5}
    
    echo "📤 Sending: $command"
    
    # Configure serial port
    stty -F $device 115200 cs8 -cstopb -parenb raw
    
    # Send command and read response
    echo -e "${command}\r\n" > $device
    sleep 1
    
    # Read response with timeout
    if timeout $timeout cat $device 2>/dev/null; then
        echo "✅ Command sent successfully"
    else
        echo "⚠️  No response or timeout"
    fi
    echo ""
}

case $mode_choice in
    1)
        echo "🔧 Configuring SIM8262A for PCIe EP Mode..."
        echo "This mode is required for use with Raspberry Pi PCIe interface"
        echo ""
        
        if [ ! -z "$USB_DEVICE" ] && [ -e "$USB_DEVICE" ]; then
            echo "📡 Sending AT commands to $USB_DEVICE..."
            
            # Enable UART
            send_at_command "AT+CCUART=1" $USB_DEVICE
            sleep 2
            
            # Set PCIe EP mode
            send_at_command "AT+CPCIEMODE=EP" $USB_DEVICE
            sleep 2
            
            # Configure USB ID for PCIe mode
            send_at_command "AT+CUSBCFG=usbid,1e0e,9001" $USB_DEVICE
            sleep 2
            
            # Reboot module to apply changes
            send_at_command "AT+CFUN=1,1" $USB_DEVICE
            
            echo "✅ PCIe EP Mode configuration completed"
            echo "⚠️  Module will reboot and should appear as PCIe device"
            
        else
            echo "❌ Cannot access AT command interface"
            echo "Please configure manually using Windows PC and serial assistant"
        fi
        ;;
        
    2)
        echo "🔧 Configuring SIM8262A for USB Mode..."
        echo "This mode is for direct connection to Windows PC"
        echo ""
        
        if [ ! -z "$USB_DEVICE" ] && [ -e "$USB_DEVICE" ]; then
            echo "📡 Sending AT commands to $USB_DEVICE..."
            
            # Configure for auto dial-up USB mode
            send_at_command "AT+CUSBCFG=usbid,1e0e,9011" $USB_DEVICE
            sleep 2
            
            # Reboot module to apply changes
            send_at_command "AT+CFUN=1,1" $USB_DEVICE
            
            echo "✅ USB Mode configuration completed"
            echo "⚠️  Module will reboot and appear as USB modem"
            
        else
            echo "❌ Cannot access AT command interface"
        fi
        ;;
        
    3)
        echo "🔍 Checking current SIM8262A configuration..."
        
        if [ ! -z "$USB_DEVICE" ] && [ -e "$USB_DEVICE" ]; then
            echo "📡 Querying module configuration..."
            
            # Check UART setting
            send_at_command "AT+CCUART?" $USB_DEVICE 3
            
            # Check PCIe mode
            send_at_command "AT+CPCIEMODE?" $USB_DEVICE 3
            
            # Check USB configuration
            send_at_command "AT+CUSBCFG?" $USB_DEVICE 3
            
            # Check module info
            send_at_command "ATI" $USB_DEVICE 3
            
        else
            echo "❌ Cannot access AT command interface"
        fi
        ;;
        
    *)
        echo "❌ Invalid option"
        exit 1
        ;;
esac

echo ""
echo "📖 Additional Information:"
echo "================================="
echo ""
echo "🔍 Module Detection Commands:"
echo "• lsusb                    - List USB devices"
echo "• lspci                    - List PCIe devices"
echo "• mmcli -L                 - List modems via ModemManager"
echo ""
echo "🛠️  Troubleshooting:"
echo "• If module not detected after mode change, power cycle it"
echo "• Check dmesg for device enumeration messages"
echo "• Verify correct USB driver installation on Windows"
echo ""
echo "📋 Required Drivers (Windows):"
echo "• SIM8200 OS Driver from Waveshare resources"
echo "• Available at: https://www.waveshare.com/wiki/SIM8262A-M2_5G_HAT%2B#Resources"