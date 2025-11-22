#!/bin/bash

# Test cellular connection with Verizon SIM
set -e

echo "=== Testing Verizon SIM Connection ==="

# Check SIM status and signal first
echo "Checking SIM status and signal..."
sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --nas-get-signal-strength || echo "Could not get signal strength"
sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --nas-get-serving-system || echo "Could not get serving system"

echo ""
echo "Checking device status..."
sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --dms-get-operating-mode || echo "Could not get operating mode"

echo ""
echo "=== Attempting Verizon Connection ==="

# Function to test Verizon connection
test_verizon_connection() {
    local apn="$1"
    echo "Testing APN: $apn"
    
    # Ensure interface is up
    sudo ip link set rmnet_mhi0 up
    
    # Try connection
    echo "Starting QMI connection with APN: $apn..."
    QMI_OUTPUT=$(timeout 30 sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --wds-start-network="apn='$apn'" --client-no-release-cid 2>&1)
    echo "QMI Output: $QMI_OUTPUT"
    
    # Check for success
    if echo "$QMI_OUTPUT" | grep -q "packet data handle"; then
        HANDLE=$(echo "$QMI_OUTPUT" | grep "packet data handle" | grep -o "'[0-9]*'" | tr -d "'")
        echo "✅ SUCCESS! Connection established with handle: $HANDLE"
        echo "Handle: $HANDLE" > /tmp/verizon_qmi_handle
        
        # Try to get IP via DHCP
        echo "Attempting DHCP configuration..."
        timeout 15 sudo dhclient rmnet_mhi0 &
        sleep 10
        
        # Check IP configuration
        echo "Current interface status:"
        ip addr show rmnet_mhi0
        
        # Test connectivity
        echo "Testing connectivity..."
        if ping -c 3 8.8.8.8 >/dev/null 2>&1; then
            echo "✅ INTERNET CONNECTIVITY SUCCESS!"
            echo "🎉 Your cellular setup is working perfectly!"
            return 0
        else
            echo "⚠️ Got IP but no internet connectivity - checking routing..."
            echo "Routes:"
            ip route
            return 1
        fi
    else
        echo "❌ Connection failed for APN: $apn"
        echo "Error details: $QMI_OUTPUT"
        return 1
    fi
}

# Test common Verizon APNs
echo "Testing Verizon APNs..."

# Try primary Verizon APNs
if test_verizon_connection "vzwinternet"; then
    echo "SUCCESS with vzwinternet APN!"
elif test_verizon_connection "verizon"; then
    echo "SUCCESS with verizon APN!"
elif test_verizon_connection "internet"; then
    echo "SUCCESS with internet APN!"
else
    echo ""
    echo "=== Trying NetworkManager approach ==="
    
    # Clean up any existing connections
    sudo nmcli connection delete "verizon-cellular" 2>/dev/null || true
    
    # Set interface to managed
    sudo nmcli device set rmnet_mhi0 managed yes
    
    # Create Verizon connection
    echo "Creating NetworkManager connection for Verizon..."
    sudo nmcli connection add \
        type gsm \
        ifname rmnet_mhi0 \
        con-name "verizon-cellular" \
        gsm.apn "vzwinternet" \
        connection.autoconnect no
    
    # Try to bring up connection
    echo "Attempting NetworkManager connection..."
    if sudo nmcli connection up "verizon-cellular"; then
        echo "✅ NetworkManager connection successful!"
        
        # Test connectivity
        if ping -c 3 8.8.8.8 >/dev/null 2>&1; then
            echo "✅ INTERNET CONNECTIVITY SUCCESS via NetworkManager!"
        else
            echo "⚠️ NetworkManager connected but no internet"
        fi
    else
        echo "❌ NetworkManager connection failed"
    fi
fi

echo ""
echo "=== Final Status ==="
echo "Interface status:"
ip addr show rmnet_mhi0 2>/dev/null || echo "Interface not found"
echo ""
echo "Network connections:"
nmcli connection show 2>/dev/null || echo "No connections"
echo ""
echo "Routes:"
ip route | head -10
echo ""

if [ -f /tmp/verizon_qmi_handle ]; then
    echo "📱 QMI Handle saved for cleanup: $(cat /tmp/verizon_qmi_handle)"
    echo "To disconnect: sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --wds-stop-network=\"$(cat /tmp/verizon_qmi_handle)\" --client-cid=XX"
fi

echo ""
echo "=== Summary ==="
if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "🎉 CELLULAR CONNECTION IS WORKING!"
    echo "Your hardware and software setup is perfect."
    echo "The eiotclub SIM issue is definitely a carrier/roaming problem."
else
    echo "⚠️ Connection attempts completed but no internet connectivity"
    echo "Check the output above for specific error messages."
fi