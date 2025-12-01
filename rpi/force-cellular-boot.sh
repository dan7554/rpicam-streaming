#!/bin/bash

# Force Cellular Connection on Boot
# This script aggressively initializes the SIM8262A modem on every boot
# It handles the PBL (bootloader) mode issue by forcing device power cycling

set -e

LOGFILE="/var/log/force-cellular-boot.log"
HOME_DIR="/home/dan7554"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

log_msg "🚀 Starting force cellular boot initialization..."

# Function to force modem out of PBL mode
force_modem_init() {
    log_msg "🔧 Forcing SIM8262A modem initialization from PBL mode..."
    
    # Step 1: Just reload pcie_mhi driver (firmware loads automatically)
    log_msg "📌 Step 1: Reloading pcie_mhi driver..."
    modprobe -r pcie_mhi 2>/dev/null || true
    sleep 3
    modprobe pcie_mhi 2>/dev/null || true
    sleep 3
    
    # Step 2: Wait extensively for firmware load (this is the KEY timing issue)
    log_msg "📌 Step 2: Waiting for firmware load sequence (this can take 30+ seconds)..."
    local fw_wait=0
    local max_fw_wait=60
    while [ $fw_wait -lt $max_fw_wait ]; do
        # Check for ANY MHI device creation (sign firmware is loading)
        if [ -c "/dev/mhi_BHI" ]; then
            log_msg "✅ MHI initialization detected"
            break
        fi
        
        if [ $((fw_wait % 10)) -eq 0 ]; then
            log_msg "⏳ Firmware loading... ($fw_wait/$max_fw_wait seconds)"
        fi
        
        sleep 1
        fw_wait=$((fw_wait + 1))
    done
    
    # Step 3: Extended wait for full modem initialization
    log_msg "📌 Step 3: Waiting for modem to leave PBL mode (30 seconds)..."
    sleep 30
    
    # Step 4: Check if more devices appeared
    log_msg "📌 Step 4: Checking for all MHI devices..."
    local device_check=0
    while [ $device_check -lt 10 ]; do
        local dev_count=$(ls /dev/mhi_* 2>/dev/null | wc -l)
        log_msg "📊 MHI devices found: $dev_count ($(ls /dev/mhi_* 2>/dev/null | tr '\n' ' '))"
        
        # If we have more than just BHI, modem is initializing
        if [ $dev_count -gt 1 ]; then
            log_msg "✅ Multiple MHI devices detected - firmware loading progressing"
            sleep 10
            break
        elif [ -c "/dev/mhi_QMI0" ]; then
            log_msg "✅ QMI device ready!"
            return 0
        fi
        
        log_msg "⏳ Waiting for device creation... ($((device_check+1))/10)"
        sleep 3
        device_check=$((device_check + 1))
    done
}

# Function to load modem firmware if needed
load_modem_firmware() {
    log_msg "📱 Attempting firmware loading sequence..."
    
    # Try using qmi-network to trigger firmware load
    if command -v qmi-network >/dev/null 2>&1; then
        log_msg "🔧 Using qmi-network to trigger firmware..."
        qmi-network /dev/mhi_QMI0 start >/dev/null 2>&1 || true
        sleep 10
    fi
    
    # Try ModemManager approach
    if command -v mmcli >/dev/null 2>&1; then
        log_msg "🔧 Using ModemManager to trigger initialization..."
        systemctl restart ModemManager
        sleep 15
        mmcli -m 0 2>/dev/null || true
    fi
}

# Function to establish QMI connection
establish_connection() {
    log_msg "🌐 Establishing QMI connection..."
    
    local max_attempts=3
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        log_msg "📱 Connection attempt $attempt/$max_attempts..."
        
        if [ -f "$HOME_DIR/qmi-connection-manager.sh" ]; then
            cd "$HOME_DIR" && ./qmi-connection-manager.sh start >> "$LOGFILE" 2>&1
            
            sleep 5
            
            # Check if connection successful
            if ip route | grep -q rmnet_mhi0; then
                log_msg "✅ QMI connection established"
                
                # Test connectivity
                if ping -c 2 -I rmnet_mhi0 8.8.8.8 >/dev/null 2>&1; then
                    log_msg "✅ Internet connectivity verified"
                    return 0
                else
                    log_msg "⚠️ Connection established but internet test failed"
                fi
            fi
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            log_msg "⏳ Retrying in 10 seconds..."
            sleep 10
        fi
    done
    
    return 1
}

# Main execution
main() {
    log_msg "════════════════════════════════════════"
    log_msg "Force Cellular Boot Initialization"
    log_msg "════════════════════════════════════════"
    
    # Try aggressive modem initialization
    force_modem_init
    
    # Extended wait for full MHI device creation (firmware load takes time)
    local wait_count=0
    while [ ! -c "/dev/mhi_QMI0" ] && [ $wait_count -lt 8 ]; do
        log_msg "⏳ Waiting for QMI device creation ($((wait_count+1))/8)..."
        
        local current_devices=$(ls /dev/mhi_* 2>/dev/null | tr '\n' ' ')
        log_msg "📊 Current devices: $current_devices"
        
        # If we see DIAG or DUN, QMI should be coming soon
        if echo "$current_devices" | grep -q "mhi_DIAG\|mhi_DUN"; then
            log_msg "✅ Firmware loading detected, waiting for QMI..."
        fi
        
        sleep 10
        wait_count=$((wait_count + 1))
    done
    
    # Attempt connection
    if establish_connection; then
        log_msg "🎉 CELLULAR INITIALIZATION COMPLETE"
        
        # Restart Tailscale to use cellular if available
        if systemctl is-enabled tailscaled >/dev/null 2>&1; then
            systemctl restart tailscaled
            sleep 5
            tailscale up --ssh --accept-routes --timeout=30s >/dev/null 2>&1 || true
        fi
        
        exit 0
    else
        log_msg "❌ Failed to establish cellular connection"
        exit 1
    fi
}

main "$@"
