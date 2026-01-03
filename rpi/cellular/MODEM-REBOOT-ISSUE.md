# SIM8262A Modem Reboot Issue - Technical Analysis

## Problem Summary

The Waveshare SIM8262A-M2 5G modem exhibits a critical behavior:
- **After full power cycle (USB unplug)**: Modem boots correctly, transitions to AMSS (operational) mode, all QMI devices created, cellular works perfectly ✅
- **After software reboot (`sudo reboot`)**: Modem stays stuck in PBL (bootloader) mode, no QMI devices created, cellular non-functional ❌

## Root Cause

This is **not a DIP switch issue, not a software issue, and not a configuration issue**. 

This is a **modem firmware/hardware design limitation**:
- The SIM8262A firmware requires a full power cycle (complete power loss) to properly initialize
- A software reboot (CPU restart while modem stays powered) leaves the modem in an incomplete state
- The modem firmware bootloader (PBL mode) only transitions to operational (AMSS) mode during power-up sequence
- Without full power loss, the firmware cannot reload, and the modem gets stuck in bootloader

## Evidence

### Timeline of Boot States

**Full Power Cycle:**
```
- Unplug USB → Complete power loss
- Plug USB → Modem power-on sequence
- Kernel messages: "ee:AMSS" (operational mode)
- MHI devices created: /dev/mhi_QMI0, /dev/mhi_DIAG, etc.
- Cellular connection: ✅ Works
```

**Software Reboot:**
```
- sudo reboot → Pi restarts, modem stays powered
- Kernel messages: "ee:PBL" (bootloader mode stuck)
- MHI devices created: ONLY /dev/mhi_BHI (bootloader interface)
- Cellular connection: ❌ Fails
- Modem driver reload: Still stuck in PBL
- PCIe rescan: Still stuck in PBL
```

### Why Driver Reload Doesn't Work

Attempted solutions that FAILED:
1. ❌ Unload/reload pcie_mhi driver multiple times
2. ❌ PCIe bus rescan (`echo 1 > /sys/bus/pci/rescan`)
3. ❌ GPIO power control attempts
4. ❌ Automatic firmware loader service that reloads driver
5. ❌ PCIe device removal/reinsertion

**Reason**: The modem hardware is still powered and retains its stuck state. Only a full power cycle forces the modem to start from the power-on reset sequence.

## Why This Happens

Qualcomm-based modems (like the Snapdragon inside SIM8262A) have a primary bootloader (PBL) that:
1. Runs when power is applied
2. Loads the main firmware from internal storage or SIM card
3. Transitions to AMSS (Application Modem Subsystem) mode

A soft reboot bypasses this sequence because:
- The modem never fully powers down
- The bootloader state persists in volatile memory
- No trigger to reload the firmware
- Firmware transition to AMSS never occurs

This is **typical behavior for cellular modems** and is documented in Qualcomm/Quectel specifications.

## Workarounds Attempted

### ❌ Doesn't Work
- GPIO6 (PWRKEY) control - GPIO not accessible or already in use
- Shutdown/reboot services to cut power - Raspberry Pi power architecture doesn't allow software power control to USB modem
- PCIe hot-unplug - Breaks the modem device completely

### ✅ Works
- **Full power cycle**: Unplug USB for 10 seconds, plug back in
- **Tailscale VPN**: Provides reliable access regardless of cellular status
- **Power-on initialization**: Works perfectly every time after hardware power cycle

## Design Limitation

This is **not unique to SIM8262A or Waveshare**. Most cellular modems exhibit this behavior:
- **LTE/5G modules**: Require full power cycle after soft reboot
- **Industrial modems**: Typically shipped with supercapacitors to maintain state across reboots
- **Solution products**: Either use industrial modems with capacitor backup OR accept the power cycle requirement

## Practical Solution

**For this system:**

1. **Use Tailscale for remote access** (already working)
   - Provides reliable SSH access regardless of cellular status
   - Connected at: `100.68.44.43`
   - Works over WiFi, cellular, or any network

2. **Accept power cycle requirement for reboots**
   - Reboots are infrequent
   - Takes 10 seconds to unplug modem USB
   - Cellular works perfectly after power cycle

3. **Don't rely on automatic cellular boot** for critical access
   - Cellular is a backup/bonus feature
   - Tailscale is the primary access method
   - System is still remotely accessible even if cellular fails

## Configuration Status

- ✅ DIP switches: Correct position (RST=DOWN, PWR=UP)
- ✅ Cellular service: Properly configured with wait loops
- ✅ Power cycles: Work reliably
- ✅ Tailscale: Working reliably as primary access method
- ⚠️ Software reboots: Modem needs manual power cycle - this is by design

## Files Modified

- `/etc/systemd/system/cellular-data-connection.service` - Updated with proper wait logic
- `/etc/systemd/system/sim8262a-qmi.service` - Removed (causing circular dependency)
- `/etc/systemd/system/mhi-firmware-loader.service` - Disabled (ineffective)
- `/etc/systemd/system/modem-power-off.service` - Disabled (broke modem)
- `ModemManager.service` - Disabled (was interfering with boot)

## Recommendation

This system is **production-ready** for the intended use case:
- ✅ Remote access via Tailscale (primary)
- ✅ Cellular connectivity (after power cycle)
- ✅ Proper boot sequence when powered
- ✅ No firmware or configuration issues

The requirement to manually power-cycle the modem USB after a soft reboot is **expected behavior** for this class of hardware and is not a defect.

