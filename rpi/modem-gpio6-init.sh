#!/bin/bash
# Use exact Waveshare GPIO6 power cycle sequence
#
# This script mimics the Waveshare approach of toggling GPIO6 to properly 
# initialize the modem before driver load

set -x
LOG_FILE="/var/log/modem-gpio6-init.log"

{
    echo "=========================================="
    echo "Modem GPIO6 Power Cycle - $(date)"
    echo "=========================================="
    
    # Check if pcie_mhi is loaded - if so, unload it first
    if lsmod | grep -q pcie_mhi; then
        echo "Unloading pcie_mhi..."
        rmmod pcie_mhi 2>/dev/null
        sleep 2
    fi
    
    # Run the exact Waveshare sequence
    echo "Running Waveshare GPIO6 power cycle..."
    python3 << 'PYTHON_END'
from gpiozero import LED
import subprocess
import time

try:
    led = LED(6)
    print("GPIO6: ON")
    led.on()
    time.sleep(0.5)
    
    print("GPIO6: OFF")
    led.off()
    
    print("Reloading pcie_mhi driver...")
    subprocess.run(['modprobe', 'pcie_mhi'])
    
    print("Waiting for modem initialization...")
    time.sleep(5)
    
    print("GPIO6 cycle complete")
except Exception as e:
    print(f"ERROR: {e}")
PYTHON_END
    
    echo "=========================================="
    
} 2>&1 | tee -a "$LOG_FILE"

exit 0
