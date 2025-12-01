# FINAL CELLULAR SETUP - WORKING CONFIGURATION

## SUCCESS: Automatic Cellular Boot is NOW WORKING! 🎉

### What was the issue?

The DIP switches on the Waveshare HAT must be in specific positions:
- **Official Documentation says:** RST=OPEN, PWR=CLOSED
- **Actually working configuration:** RST=CLOSED, PWR=OPEN ⭐

This was the critical missing piece! The hardware board requires the OPPOSITE of what the official docs say.

### Current Working Status

After setting DIP switches correctly and doing a full power cycle:

✅ **Modem Detection**: Qualcomm 17cb:0308 detected on PCIe  
✅ **MHI Devices**: All created automatically (/dev/mhi_QMI0, /dev/mhi_DIAG, /dev/mhi_DUN, /dev/mhi_LOOPBACK)  
✅ **Cellular Connection**: 192.0.0.2 with internet access  
✅ **Network Speed**: 18-21ms latency to Google DNS  
✅ **Public IP**: 174.162.192.174 (T-Mobile 5G NSA)  
✅ **Tailscale**: Connected at 100.68.44.43  
✅ **SSH Access**: Available via Tailscale from anywhere  

### Boot Sequence (Clean)

```
1. Power on
2. Kernel boots
3. PCIe bus initializes (with correct DIP settings)
4. pcie_mhi driver loads and detects modem
5. MHI devices created (~4-5 seconds into boot)
6. waveshare-CM starts and establishes connection (~6-10 seconds)
7. System fully ready (~20 seconds)
```

### What was BLOCKING progress?

Multiple old systemd services were interfering:
- `cellular-boot-manager.service` - forced driver reloads
- `force-cellular-boot.service` - aggressive driver reloads
- `modem-reset-init.service` - GPIO manipulation causing issues
- `cellular-watchdog.service` - monitoring conflicts

These have been **disabled and masked** to prevent interference.

### How to replicate this setup on a fresh install

1. **Set DIP switches:**
   - RST = DOWN/CLOSED ← (Key!)
   - PWR = UP/OPEN ← (Key!)

2. **Full power cycle** (not just reboot):
   - Unplug power for 10+ seconds
   - Power back on

3. **Install only the essential service:**
   ```bash
   sudo cp rpi/cellular-data-connection.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable cellular-data-connection.service
   ```

4. **Disable old/conflicting services:**
   ```bash
   sudo systemctl disable \
     cellular-boot-manager.service \
     force-cellular-boot.service \
     modem-reset-init.service \
     cellular-watchdog.service
   sudo systemctl daemon-reload
   ```

5. **Reboot and verify:**
   ```bash
   sudo reboot
   sleep 30
   
   # Should all work:
   ls -la /dev/mhi_*
   ip addr show rmnet_mhi0
   ping 8.8.8.8
   tailscale status
   ```

### Remote Access Methods

**Option 1: Tailscale (Best)**
```bash
ssh dan7554@100.68.44.43
```

**Option 2: Direct Cellular IP**
```bash
# Get current public IP
curl -s https://ifconfig.io --interface rmnet_mhi0.1

# SSH to it
ssh dan7554@<public-ip>
```

### Hardware Notes

- **Board**: Waveshare SIM8262A-M2 5G HAT+
- **Modem**: Qualcomm SIM8262A-M2 (Quectel MHI driver)
- **RPi**: Raspberry Pi 5 with custom Waveshare kernel (6.6.23-v8-16k-waveshare+)
- **Network**: T-Mobile 5G NSA
- **Driver**: Quectel MHI driver v1.3.6

### Active Services After Cleanup

```
✅ tailscaled.service - Tailscale VPN
✅ cellular-data-connection.service - Waveshare-CM cellular manager
✅ ModemManager.service - System modem management
✅ network-online.target - Networking
```

### The Real Lesson

**DIP switches control hardware-level behavior.** When the official documentation didn't work, the correct approach was to:
1. Physically test different switch configurations
2. Identify what actually works
3. Document the REAL configuration (not the theoretical one)

For your specific board/revision: **RST=CLOSED, PWR=OPEN** is the magic combination.
