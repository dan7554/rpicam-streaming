#!/bin/bash
# Combined GPIO5 (reset) + GPIO6 (power) cycle for modem initialization
# 
# GPIO5: Reset (active-low) 
# GPIO6: Power control (PWRKEY)
#
# Sequence:
# 1. Reset the modem (GPIO5 low then high)
# 2. Cycle power (GPIO6 on/off)
# 3. Load driver and wait for initialization

set -x
LOG_FILE="/var/log/modem-gpio-init.log"

{
    echo "=========================================="
    echo "Modem GPIO Initialization - $(date)"
    echo "=========================================="
    
    # Unload driver if present
    if lsmod | grep -q pcie_mhi; then
        echo "Unloading existing pcie_mhi..."
        rmmod pcie_mhi
        sleep 2
    fi
    
    echo "Running combined GPIO5+GPIO6 initialization..."
    python3 << 'PYTHON_END'
from gpiozero import LED
import time
import subprocess

try:
    print("Initializing GPIO pins...")
    reset_pin = LED(5)   # GPIO5: Reset
    power_pin = LED(6)   # GPIO6: Power
    
    # Step 1: Reset (GPIO5 low->high)
    print("[1] GPIO5 RESET: LOW (assert reset)")
    reset_pin.off()
    time.sleep(0.2)
    
    print("[1] GPIO5 RESET: HIGH (release reset)")
    reset_pin.on()
    time.sleep(0.5)
    
    # Step 2: Power cycle (GPIO6)
    print("[2] GPIO6 POWER: ON")
    power_pin.on()
    time.sleep(0.5)
    
    print("[2] GPIO6 POWER: OFF")
    power_pin.off()
    time.sleep(0.5)
    
    print("[3] GPIO sequence complete")
    
except Exception as e:
    print(f"GPIO error: {e}")
    import traceback
    traceback.print_exc()
PYTHON_END
    
    echo "Waiting for modem to stabilize..."
    sleep 3
    
    echo "Loading pcie_mhi driver..."
    modprobe pcie_mhi
    
    echo "Waiting for device enumeration..."
    sleep 5
    
    if ls /dev/mhi_* 2>/dev/null > /dev/null; then
        echo "Devices created successfully:"
        ls -la /dev/mhi_*
    else
        echo "No devices created"
    fi
    
    echo "=========================================="
    echo "Complete - $(date)"
    echo "=========================================="
    
} 2>&1 | tee -a "$LOG_FILE"

exit 0
