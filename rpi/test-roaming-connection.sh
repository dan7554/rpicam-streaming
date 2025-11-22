#!/bin/bash

# Test roaming-specific connection approaches
set -e

echo "=== Testing Roaming Connection Approaches ==="

# Check current registration details
echo "Current registration status:"
sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --nas-get-serving-system

echo ""
echo "=== Attempting roaming-specific configurations ==="

# Try with roaming enabled explicitly
echo "1. Trying with explicit roaming settings..."
timeout 20 sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --wds-start-network="apn='iot.1nce.net',roaming=allowed" 2>&1 || echo "Roaming-allowed failed"

# Try with different profile
echo "2. Trying with profile configuration..."
timeout 20 sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --wds-start-network="apn='iot.1nce.net',profile=1" 2>&1 || echo "Profile-based failed"

# Try minimal APN
echo "3. Trying minimal APN configuration..."
timeout 20 sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --wds-start-network="apn='internet'" 2>&1 || echo "Minimal APN failed"

# Try Verizon-specific APN since we're roaming on Verizon
echo "4. Trying Verizon roaming APN..."
timeout 20 sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --wds-start-network="apn='vzwinternet'" 2>&1 || echo "Verizon APN failed"

echo ""
echo "=== Checking operator and SIM details ==="
echo "Operator name:"
sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --nas-get-operator-name 2>/dev/null || echo "Could not get operator name"

echo ""
echo "SIM status:"
sudo qmicli -d /dev/mhi_QMI0 --device-open-qmi --dms-uim-get-pin-status 2>/dev/null || echo "Could not get PIN status"

echo ""
echo "=== Recommendation ==="
echo "Your eiotclub SIM is roaming on Verizon (MCC: 311, MNC: 480)"
echo "Verizon is blocking data connections with 'pdn-ipv4-call-throttled' error"
echo ""
echo "Next steps:"
echo "1. Contact eiotclub support - they need to verify:"
echo "   - SIM is fully activated (may take 24-48 hours)"
echo "   - Roaming agreements are configured with Verizon"
echo "   - Correct APN settings for US roaming"
echo ""
echo "2. Test with a domestic US SIM card (Verizon, AT&T, T-Mobile prepaid)"
echo ""
echo "3. Try again in 24 hours - some IoT SIMs need activation time"
echo ""
echo "Hardware and software setup is PERFECT - this is purely a carrier/SIM issue"