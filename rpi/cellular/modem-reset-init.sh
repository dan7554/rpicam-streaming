#!/bin/bash
# Modem Reset via GPIO5
# Reset the modem without killing the PCIe link
# GPIO5: Module reset (connected to RESET_N pin)
#
# This is safer than GPIO6 (power) cycling which can bring down the PCIe link

set -x

LOG_FILE="/var/log/modem-reset-init.log"
{
    echo "=========================================="
    echo "Modem Reset Initialization - $(date)"
    echo "=========================================="
    
    # Step 1: Unload any existing pcie_mhi driver
    echo "[STEP 1] Checking and unloading existing pcie_mhi driver..."
    if lsmod | grep -q pcie_mhi; then
        echo "  - pcie_mhi is loaded, unloading..."
        rmmod pcie_mhi 2>/dev/null || echo "  - rmmod failed or not loaded"
        sleep 1
    fi
    
    # Step 2: Reset via GPIO5
    echo "[STEP 2] Resetting modem via GPIO5..."
    
    if command -v python3 &> /dev/null && python3 -c "import gpiozero" 2>/dev/null; then
        echo "  - Using gpiozero library for GPIO5 reset"
        python3 << 'PYTHON_END'
from gpiozero import LED
import time

try:
    # GPIO5 is typically active-low reset (set LOW to reset, HIGH to release)
    reset_pin = LED(5)
    
    print("  - GPIO5: Setting LOW (asserting reset)")
    reset_pin.off()  # off() sets to LOW
    time.sleep(0.5)
    
    print("  - GPIO5: Setting HIGH (releasing reset)")
    reset_pin.on()  # on() sets to HIGH
    time.sleep(1.0)
    
    print("  - GPIO5 reset complete")
except Exception as e:
    print(f"  - GPIO5 reset failed: {e}")
PYTHON_END
    else
        echo "  - gpiozero not available, trying sysfs"
        
        # Try GPIO5
        if [ ! -d /sys/class/gpio/gpio5 ]; then
            echo 5 > /sys/class/gpio/export 2>/dev/null
            sleep 0.5
        fi
        
        if [ -d /sys/class/gpio/gpio5 ]; then
            echo "out" > /sys/class/gpio/gpio5/direction 2>/dev/null
            
            echo "  - GPIO5: Setting LOW (reset)"
            echo 0 > /sys/class/gpio/gpio5/value 2>/dev/null
            sleep 0.5
            
            echo "  - GPIO5: Setting HIGH (release)"
            echo 1 > /sys/class/gpio/gpio5/value 2>/dev/null
            sleep 1.0
            
            echo 5 > /sys/class/gpio/unexport 2>/dev/null
            echo "  - GPIO5 reset complete"
        fi
    fi
    
    # Step 3: Wait for modem to stabilize
    echo "[STEP 3] Waiting for modem to stabilize..."
    sleep 2
    
    # Step 4: Reload pcie_mhi driver
    echo "[STEP 4] Loading pcie_mhi driver..."
    modprobe pcie_mhi
    sleep 2
    
    # Step 5: Check devices
    echo "[STEP 5] Checking MHI devices..."
    if ls /dev/mhi_* 2>/dev/null; then
        echo "  - MHI devices created:"
        ls -la /dev/mhi_*
    else
        echo "  - Waiting for device enumeration..."
        sleep 5
        if ls /dev/mhi_* 2>/dev/null; then
            echo "  - MHI devices now available:"
            ls -la /dev/mhi_*
        else
            echo "  - No MHI devices created"
        fi
    fi
    
    echo "[SUCCESS] Modem reset initialization complete - $(date)"
    echo "=========================================="
    
} 2>&1 | tee -a "$LOG_FILE"

exit 0
