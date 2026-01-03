#!/bin/bash
# Modem Power Initialization Script
# Cycles GPIO6 (power) to bring SIM8262A out of PBL bootloader mode
# This must run BEFORE the pcie_mhi driver initializes
# 
# GPIO6: Module power control (connected to PWRKEY pin)
# Expected sequence: Power cycle + driver reload = proper firmware load

set -x  # Enable command echoing for debugging

LOG_FILE="/var/log/modem-power-init.log"
{
    echo "=========================================="
    echo "Modem Power Initialization - $(date)"
    echo "=========================================="
    
    # Step 1: Unload any existing pcie_mhi driver
    echo "[STEP 1] Checking and unloading existing pcie_mhi driver..."
    if lsmod | grep -q pcie_mhi; then
        echo "  - pcie_mhi is loaded, unloading..."
        rmmod pcie_mhi 2>/dev/null || echo "  - rmmod failed or not loaded"
        sleep 2
    else
        echo "  - pcie_mhi not loaded (this is the normal boot state)"
    fi
    
    # Step 2: Check if gpiozero is available, otherwise use sysfs
    echo "[STEP 2] Cycling GPIO6 (modem power)..."
    
    if command -v python3 &> /dev/null && python3 -c "import gpiozero" 2>/dev/null; then
        echo "  - Using gpiozero library"
        python3 << 'PYTHON_END'
from gpiozero import LED
import time

try:
    led = LED(6)
    print("  - GPIO6: Setting HIGH (power ON)")
    led.on()
    time.sleep(0.5)
    
    print("  - GPIO6: Setting LOW (power OFF)")
    led.off()
    print("  - GPIO6 power cycle complete")
except Exception as e:
    print(f"  - GPIO control failed: {e}")
PYTHON_END
    else
        echo "  - gpiozero not available, using sysfs (need to export GPIO6 first)"
        
        # Export GPIO6 if not already exported
        if [ ! -d /sys/class/gpio/gpio6 ]; then
            echo 6 > /sys/class/gpio/export 2>/dev/null || echo "  - Failed to export GPIO6"
            sleep 0.5
        fi
        
        if [ -d /sys/class/gpio/gpio6 ]; then
            # Set as output
            echo "out" > /sys/class/gpio/gpio6/direction 2>/dev/null
            
            # Power ON
            echo "  - GPIO6: Setting HIGH (power ON)"
            echo 1 > /sys/class/gpio/gpio6/value 2>/dev/null
            sleep 0.5
            
            # Power OFF
            echo "  - GPIO6: Setting LOW (power OFF)"
            echo 0 > /sys/class/gpio/gpio6/value 2>/dev/null
            sleep 0.5
            
            # Clean up
            echo 6 > /sys/class/gpio/unexport 2>/dev/null
            echo "  - GPIO6 power cycle complete"
        else
            echo "  - ERROR: Could not access GPIO6"
        fi
    fi
    
    # Step 3: Wait for modem to stabilize
    echo "[STEP 3] Waiting for modem to stabilize after power cycle..."
    sleep 3
    
    # Step 4: Reload pcie_mhi driver
    echo "[STEP 4] Loading pcie_mhi driver..."
    modprobe pcie_mhi
    sleep 2
    
    # Step 5: Check what devices were created
    echo "[STEP 5] Checking created MHI devices..."
    if ls /dev/mhi_* 2>/dev/null; then
        echo "  - MHI devices created:"
        ls -la /dev/mhi_*
    else
        echo "  - No MHI devices created yet"
    fi
    
    echo "[SUCCESS] Modem power initialization complete - $(date)"
    echo "=========================================="
    
} 2>&1 | tee -a "$LOG_FILE"

exit 0
