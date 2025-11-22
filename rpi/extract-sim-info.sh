#!/bin/bash

# Extract SIM and device information for carrier activation
set -e

echo "==========================================================="
echo "📋 SIM ACTIVATION INFORMATION EXTRACTOR"
echo "==========================================================="
echo "Collecting all data needed for eiotclub/1NCE support"
echo ""

LOG_FILE="/tmp/sim_activation_info.txt"
echo "📋 SIM ACTIVATION INFORMATION - $(date)" > $LOG_FILE
echo "==========================================================" >> $LOG_FILE

# Function to log and display
log_info() {
    echo "$1"
    echo "$1" >> $LOG_FILE
}

echo "🔍 EXTRACTING DEVICE INFORMATION..."

# 1. Hardware Information
log_info ""
log_info "1. HARDWARE INFORMATION:"
log_info "========================"
log_info "Device: Raspberry Pi 5 with SIM8262A-M2 5G Module"
log_info "Connection: PCIe (MHI interface)"
log_info "Location: USA"

# 2. SIM Card Information
echo "📱 Checking SIM card details..."
log_info ""
log_info "2. SIM CARD INFORMATION:"
log_info "========================"

# Get IMEI
echo "Getting device IMEI..."
IMEI=$(sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --dms-get-ids 2>/dev/null | grep -i "imei" | cut -d"'" -f2 || echo "Not available")
log_info "IMEI: $IMEI"

# Try to get ICCID (SIM serial number)
echo "Getting SIM ICCID..."
ICCID=$(sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --dms-uim-get-iccid 2>/dev/null | grep -i "iccid" | cut -d"'" -f2 || echo "Not supported by this interface")
log_info "ICCID (SIM Serial): $ICCID"

# Try alternative method for ICCID
if [ "$ICCID" = "Not supported by this interface" ]; then
    echo "Trying alternative ICCID method..."
    ICCID_ALT=$(sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --uim-get-card-status 2>/dev/null | grep -i "iccid" | head -1 || echo "Not available")
    log_info "ICCID (alternative): $ICCID_ALT"
fi

# Get IMSI if possible
echo "Getting IMSI..."
IMSI=$(sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --dms-uim-get-imsi 2>/dev/null | grep -i "imsi" | cut -d"'" -f2 || echo "Not available")
log_info "IMSI: $IMSI"

# 3. Network Registration Information
echo "📡 Checking network registration..."
log_info ""
log_info "3. NETWORK REGISTRATION:"
log_info "========================"

# Get serving system info
NETWORK_INFO=$(sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --nas-get-serving-system 2>/dev/null)
echo "$NETWORK_INFO" | while read line; do
    if echo "$line" | grep -q -E "(Registration state|MCC|MNC|Description|Roaming status)"; then
        log_info "$line"
    fi
done

# Extract specific values
MCC=$(echo "$NETWORK_INFO" | grep "MCC:" | head -1 | awk '{print $2}' | tr -d "'" || echo "Unknown")
MNC=$(echo "$NETWORK_INFO" | grep "MNC:" | head -1 | awk '{print $2}' | tr -d "'" || echo "Unknown")
CARRIER=$(echo "$NETWORK_INFO" | grep "Description:" | head -1 | cut -d"'" -f2 || echo "Unknown")

log_info ""
log_info "Network Details:"
log_info "- Mobile Country Code (MCC): $MCC"
log_info "- Mobile Network Code (MNC): $MNC" 
log_info "- Carrier: $CARRIER"
log_info "- Combined PLMN: $MCC$MNC"

# 4. Signal Information
echo "📶 Checking signal strength..."
log_info ""
log_info "4. SIGNAL INFORMATION:"
log_info "======================"

SIGNAL_INFO=$(sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --nas-get-signal-strength 2>/dev/null)
echo "$SIGNAL_INFO" | while read line; do
    if echo "$line" | grep -q -E "(Network 'lte'|RSRP|RSRQ|SINR)"; then
        log_info "$line"
    fi
done

# 5. Device Capabilities
echo "⚙️ Checking device capabilities..."
log_info ""
log_info "5. DEVICE CAPABILITIES:"
log_info "======================="

CAPABILITIES=$(sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --dms-get-capabilities 2>/dev/null)
echo "$CAPABILITIES" | while read line; do
    if echo "$line" | grep -q -E "(Networks|SIM)"; then
        log_info "$line"
    fi
done

# 6. Connection Errors
echo "❌ Recording connection errors..."
log_info ""
log_info "6. CONNECTION ERROR DETAILS:"
log_info "============================"

# Try connection and capture specific error
echo "Testing connection to capture exact error..."
CONNECTION_ERROR=$(sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --wds-start-network="apn='iot.1nce.net'" 2>&1 || true)
log_info "Error when connecting with APN 'iot.1nce.net':"
echo "$CONNECTION_ERROR" | while read line; do
    if echo "$line" | grep -q -E "(error|call end reason|verbose call end reason)"; then
        log_info "$line"
    fi
done

# 7. Interface Information
log_info ""
log_info "7. INTERFACE INFORMATION:"
log_info "========================="
log_info "Network Interface: rmnet_mhi0"
log_info "Interface Type: MHI (Modem Host Interface)"
log_info "Driver: mhi_q"
log_info "QMI Device: /dev/mhi_QMI0"

# 8. Recommended APN Configurations to Test
log_info ""
log_info "8. RECOMMENDED APN CONFIGURATIONS:"
log_info "=================================="
log_info "Primary APN: iot.1nce.net"
log_info "Alternative APNs to test:"
log_info "- 1nce.net"
log_info "- internet.1nce.net"
log_info "- m2m.1nce.net"
log_info "Authentication: None (username/password empty)"
log_info "IP Type: IPv4, IPv6, or IPv4v6"

# 9. Carrier-Specific Information
log_info ""
log_info "9. CARRIER-SPECIFIC ROAMING INFO:"
log_info "================================="
if [ "$MCC" = "311" ] && [ "$MNC" = "480" ]; then
    log_info "ROAMING ON: Verizon Wireless (USA)"
    log_info "Issue: Verizon blocks most roaming data connections"
    log_info "Required: Roaming agreement between eiotclub and Verizon"
    log_info "Alternative: Request different roaming partner (AT&T, T-Mobile)"
elif [ "$MCC" = "310" ] || [ "$MCC" = "311" ]; then
    log_info "ROAMING IN: United States"
    log_info "Detected Carrier: $CARRIER"
    log_info "May require specific roaming agreements"
else
    log_info "Network: $CARRIER (MCC: $MCC, MNC: $MNC)"
fi

log_info ""
log_info "10. TECHNICAL SPECIFICATIONS:"
log_info "============================="
log_info "Modem: Qualcomm-based SIM8262A-M2"
log_info "Protocols: QMI, MBIM"
log_info "Bands: 5G NR, LTE, UMTS"
log_info "Interface: PCIe via MHI driver"
log_info "OS: Debian GNU/Linux on Raspberry Pi"

echo ""
echo "📄 COMPLETE INFORMATION SAVED TO: $LOG_FILE"
echo ""
echo "==========================================================="
echo "📋 SUMMARY FOR EIOTCLUB/1NCE SUPPORT:"
echo "==========================================================="
echo "IMEI: $IMEI"
echo "ICCID: $ICCID"
echo "Current Network: $CARRIER (MCC: $MCC, MNC: $MNC)"
echo "Error: pdn-ipv4-call-throttled (carrier blocking connection)"
echo "Hardware: Working perfectly (tested with Verizon SIM)"
echo "Issue: Roaming restrictions on current carrier"
echo ""
echo "🎯 KEY QUESTIONS FOR EIOTCLUB SUPPORT:"
echo "1. Is this SIM activated for US roaming?"
echo "2. Does eiotclub have roaming agreement with Verizon (311-480)?"
echo "3. What APN should be used for US roaming?"
echo "4. Can you switch to AT&T or T-Mobile roaming partner?"
echo "5. Is there an activation waiting period?"
echo ""
echo "📧 Email this file ($LOG_FILE) to eiotclub support"
echo "==========================================================="

# Display the file for easy copying
echo ""
echo "📋 FILE CONTENTS (for copy/paste to support):"
echo "=============================================="
cat $LOG_FILE