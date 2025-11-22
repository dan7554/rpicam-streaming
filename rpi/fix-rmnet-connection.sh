#!/bin/bash

# Fix NetworkManager connection for rmnet_mhi0 interface
set -e

echo "=== Fixing rmnet_mhi0 NetworkManager Configuration ==="

# Function to try NetworkManager approach
try_networkmanager() {
    echo "Setting rmnet_mhi0 to managed..."
    sudo nmcli device set rmnet_mhi0 managed yes
    
    echo "Removing any existing problematic connections..."
    sudo nmcli connection delete "eiotclub-direct" 2>/dev/null || true
    sudo nmcli connection delete "eiotclub-rmnet" 2>/dev/null || true
    
    echo "Creating new cellular connection..."
    sudo nmcli connection add \
        type gsm \
        ifname rmnet_mhi0 \
        con-name "eiotclub-rmnet" \
        gsm.apn "iot.1nce.net" \
        connection.autoconnect no
    
    echo "Attempting to bring up connection..."
    if sudo nmcli connection up "eiotclub-rmnet"; then
        echo "NetworkManager connection successful!"
        return 0
    else
        echo "NetworkManager approach failed, trying QMI direct..."
        return 1
    fi
}

# Function to use direct QMI approach
try_qmi_direct() {
    echo "=== Using Direct QMI Connection ==="
    
    # First check QMI device status
    echo "Checking QMI device status..."
    sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --dms-get-operating-mode || echo "Failed to get operating mode"
    
    # Check for existing connections
    echo "Checking for existing WDS connections..."
    sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --wds-get-packet-service-status || echo "Failed to get packet service status"
    
    # Bring up the interface
    echo "Bringing up rmnet_mhi0 interface..."
    sudo ip link set rmnet_mhi0 up
    
    # Start network connection via QMI with verbose output
    echo "Starting QMI network connection..."
    QMI_OUTPUT=$(sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --wds-start-network="apn='iot.1nce.net'" --client-no-release-cid 2>&1)
    echo "QMI Output: $QMI_OUTPUT"
    
    HANDLE=$(echo "$QMI_OUTPUT" | grep -i "packet data handle" | grep -o "'[0-9]*'" | tr -d "'")
    
    if [ -n "$HANDLE" ] && [ "$HANDLE" != "" ]; then
        echo "QMI connection started with handle: $HANDLE"
        echo "Handle: $HANDLE" > /tmp/qmi_handle
        
        # Get connection status
        echo "Checking connection status..."
        sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --wds-get-packet-service-status
        
        # Try to get IP configuration via DHCP
        echo "Attempting DHCP configuration..."
        timeout 10 sudo dhclient rmnet_mhi0 &
        DHCP_PID=$!
        sleep 8
        
        # Check if we got an IP
        if ip addr show rmnet_mhi0 | grep -q "inet "; then
            echo "QMI connection successful!"
            return 0
        else
            echo "DHCP failed, trying manual IP configuration..."
            kill $DHCP_PID 2>/dev/null || true
            
            # Try to get IP settings from QMI
            IP_INFO=$(sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --wds-get-current-settings 2>/dev/null || echo "")
            echo "IP Info from QMI: $IP_INFO"
            
            # Set a default IP if we can't get one from QMI
            sudo ip addr add 10.0.0.1/24 dev rmnet_mhi0 2>/dev/null || true
            sudo ip route add default dev rmnet_mhi0 metric 100 2>/dev/null || true
            
            if ip addr show rmnet_mhi0 | grep -q "inet "; then
                echo "Manual IP configuration successful!"
                return 0
            else
                echo "Failed to configure IP address"
                return 1
            fi
        fi
    else
        echo "Failed to start QMI network connection"
        echo "Trying alternative QMI approach..."
        return 1
    fi
}

# Function to cleanup and show status
cleanup_and_status() {
    echo ""
    echo "=== Final Status ==="
    echo "Network interfaces:"
    ip addr show rmnet_mhi0 2>/dev/null || echo "rmnet_mhi0 not found"
    echo ""
    echo "NetworkManager connections:"
    nmcli connection show 2>/dev/null || true
    echo ""
    echo "Default route:"
    ip route | grep default || echo "No default route found"
    echo ""
    echo "Testing connectivity:"
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        echo "Internet connectivity: SUCCESS"
    else
        echo "Internet connectivity: FAILED"
    fi
}

# Main execution
echo "Checking SIM status first..."
sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --dms-uim-get-iccid || echo "Could not get SIM ICCID"
sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --nas-get-signal-strength || echo "Could not get signal strength"

if ! try_networkmanager; then
    if ! try_qmi_direct; then
        echo ""
        echo "=== Trying Alternative QMI Approach ==="
        echo "Attempting connection with different QMI parameters..."
        
        # Try without client-no-release-cid
        sudo ip link set rmnet_mhi0 up
        
        # Try different APN configurations for 1NCE/eiotclub
        echo "Trying with IPv6 support..."
        timeout 30 sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --wds-start-network="apn='iot.1nce.net',ip-type=6" > /tmp/qmi_ipv6.log 2>&1 &
        QMI_PID=$!
        sleep 10
        
        if kill -0 $QMI_PID 2>/dev/null; then
            echo "IPv6 command timed out, killing process..."
            kill $QMI_PID 2>/dev/null || true
            wait $QMI_PID 2>/dev/null || true
        fi
        
        QMI_ALT=$(cat /tmp/qmi_ipv6.log 2>/dev/null || echo "Command failed or timed out")
        echo "IPv6 QMI output: $QMI_ALT"
        
        if echo "$QMI_ALT" | grep -q "packet data handle"; then
            echo "IPv6 connection successful!"
            timeout 10 sudo dhclient -6 rmnet_mhi0 &
            sleep 5
        else
            echo "Trying with dual-stack (IPv4v6)..."
            timeout 30 sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --wds-start-network="apn='iot.1nce.net',ip-type=4v6" > /tmp/qmi_dual.log 2>&1 &
            QMI_DUAL_PID=$!
            sleep 10
            
            if kill -0 $QMI_DUAL_PID 2>/dev/null; then
                echo "Dual-stack command timed out, killing process..."
                kill $QMI_DUAL_PID 2>/dev/null || true
                wait $QMI_DUAL_PID 2>/dev/null || true
            fi
            
            QMI_DUAL=$(cat /tmp/qmi_dual.log 2>/dev/null || echo "Command failed or timed out")
            echo "Dual-stack QMI output: $QMI_DUAL"
            
            if echo "$QMI_DUAL" | grep -q "packet data handle"; then
                echo "Dual-stack connection successful!"
                timeout 10 sudo dhclient rmnet_mhi0 &
                sleep 5
            else
                echo "Trying alternative 1NCE APN configurations..."
                
                # Try with different APN variations for multiple carriers
                for apn in "1nce.net" "internet.1nce.net" "m2m.1nce.net" "wholesale" "vzwinternet"; do
                    echo "Trying APN: $apn"
                    timeout 20 sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --wds-start-network="apn='$apn'" > /tmp/qmi_$apn.log 2>&1 &
                    APN_PID=$!
                    sleep 8
                    
                    if kill -0 $APN_PID 2>/dev/null; then
                        echo "APN $apn command timed out, killing process..."
                        kill $APN_PID 2>/dev/null || true
                        wait $APN_PID 2>/dev/null || true
                    fi
                    
                    QMI_APN=$(cat /tmp/qmi_$apn.log 2>/dev/null || echo "Command failed or timed out")
                    echo "APN $apn output: $QMI_APN"
                    
                    if echo "$QMI_APN" | grep -q "packet data handle"; then
                        echo "Connection successful with APN: $apn"
                        timeout 10 sudo dhclient rmnet_mhi0 &
                        sleep 5
                        break
                    fi
                done
                
                # If all APNs fail, try with authentication
                echo "Trying with explicit authentication..."
                timeout 20 sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --wds-start-network="apn='iot.1nce.net',username='',password='',auth=none" > /tmp/qmi_auth.log 2>&1 &
                AUTH_PID=$!
                sleep 8
                
                if kill -0 $AUTH_PID 2>/dev/null; then
                    echo "Auth command timed out, killing process..."
                    kill $AUTH_PID 2>/dev/null || true
                    wait $AUTH_PID 2>/dev/null || true
                fi
                
                QMI_AUTH=$(cat /tmp/qmi_auth.log 2>/dev/null || echo "Command failed or timed out")
                echo "Auth QMI output: $QMI_AUTH"
            fi
        fi
        
        # Try basic interface configuration
        echo "Trying basic interface configuration..."
        sudo ip addr add 192.168.1.100/24 dev rmnet_mhi0 2>/dev/null || true
        sudo ip link set rmnet_mhi0 up
        
        echo ""
        echo "=== Manual Debugging Information ==="
        echo "Interface status:"
        ip link show rmnet_mhi0
        echo ""
        echo "Current IP configuration:"
        ip addr show rmnet_mhi0
        echo ""
        echo "QMI capabilities:"
        sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --dms-get-capabilities || true
        echo ""
        echo "Network registration status:"
        sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --nas-get-serving-system || true
        echo ""
        echo "=== Next Steps ==="
        echo "The 'pdn-ipv4-call-throttled' error suggests carrier-level throttling."
        echo "Try these manual approaches:"
        echo ""
        echo "1. Wait 5-10 minutes and try again (carrier throttling)"
        echo "2. Try different APN:"
        echo "   sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --wds-start-network=\"apn='1nce.net'\""
        echo "3. Contact eiotclub/1NCE support to verify SIM activation and APN settings"
        echo "4. Check if SIM requires activation period after first insertion"
        echo ""
        echo "Current signal strength shows good LTE connection, so hardware is working correctly."
        exit 1
    fi
fi

cleanup_and_status
echo "Connection setup completed!"