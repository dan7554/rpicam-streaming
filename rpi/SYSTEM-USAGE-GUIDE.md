# System Usage Guide - Practical Setup

## Quick Start

### Initial Setup (After Hardware Power-On)
```bash
# SSH into system - will boot with Tailscale VPN automatically
ssh dan7554@rpicam2.local  
# or via Tailscale if on same network
ssh dan7554@100.68.44.43
```

### Check System Status
```bash
# View IP addresses
ip addr | grep -E "inet|rmnet"

# Check Tailscale status
tailscale status

# Check cellular modem
lspci | grep Qualcomm        # Should show: "Device 0308"
ls -la /dev/mhi_QMI*         # Should exist if cellular working
```

### Activate Cellular Connection

**Only needed if modem is in bootloader mode (no QMI devices):**

```bash
# Full power cycle the modem
# 1. Unplug modem USB cable
# 2. Wait 10 seconds
# 3. Plug modem USB cable back in
# 4. Wait 30 seconds for device to initialize

# Verify devices created
ls /dev/mhi_QMI0

# Start cellular connection
sudo systemctl status cellular-data-connection.service

# Check for IP on cellular interface
ip addr | grep 192.0.0
```

## Common Tasks

### Remote Access (Always Works)
```bash
# Via Tailscale (primary method - works anywhere)
ssh dan7554@100.68.44.43

# Via local network
ssh dan7554@rpicam2.local
```

### Check Cellular Status
```bash
# Quick status
ip addr | grep rmnet_mhi0 && echo "Cellular: UP" || echo "Cellular: DOWN"

# Detailed status
sudo systemctl status cellular-data-connection.service
journalctl -u cellular-data-connection.service -n 20
```

### Reboot System
```bash
# DO NOT use sudo reboot for remote reboots
# 1. Plan for Tailscale to go down briefly
# 2. After reboot, modem will be in bootloader (PBL mode)
# 3. Cellular will not work until you power-cycle the modem USB

sudo reboot

# Alternative: SSH in and run later
# (this gives you time to prepare for modem reboot)
```

### Power-Cycle Modem (When Needed)

After any reboot or if modem gets stuck:

```bash
# 1. Unplug USB cable to modem (Waveshare board)
# 2. Wait 10 seconds
# 3. Plug USB cable back in
# 4. Wait 30 seconds

# Verify:
lspci -d 17cb:0308          # Should show modem detected
ls /dev/mhi_*               # Should show QMI0, DIAG, DUN, LOOPBACK, BHI
```

## System Architecture

### Network Interfaces
- **Tailscale (tun0)**: VPN mesh network - ALWAYS AVAILABLE
  - IP: 100.68.44.43
  - Status: Auto-start on boot
  - Reliability: ✅ Very reliable (only fails if network completely down)

- **Cellular (rmnet_mhi0.1)**: 5G/LTE mobile network
  - IP: 192.0.0.2 (from modem)
  - Status: Manual start after power cycle
  - Reliability: ✅ Perfect when working, requires hardware power cycle to re-enable

- **Ethernet (eth0)**: Local network
  - Status: DHCP
  - Reliability: ✅ When connected

### Service Status

Check boot services:
```bash
# All cellular/modem related services
sudo systemctl list-unit-files | grep -i cellular
sudo systemctl list-unit-files | grep -i modem

# Should see:
# cellular-data-connection.service        enabled
# sim8262a-qmi.service                   enabled
# mhi-firmware-loader.service            enabled

# Services that are DISABLED (don't change these):
# ModemManager.service                   disabled (causes conflicts)
# cellular-boot-manager.service          disabled (causes conflicts)
# modem-reset-init.service               disabled (GPIO issues)
# modem-power-init.service               disabled (GPIO issues)
```

## Troubleshooting

### "No cellular connection after power-on"

**Symptoms:**
```
$ ls /dev/mhi_*
/dev/mhi_BHI  (only this, no QMI0)

$ dmesg | grep ee:
[3.423] ee:PBL  (bootloader mode)
```

**Solution:**
1. Power-cycle modem USB (unplug 10 sec, plug back in)
2. Check for QMI devices: `ls /dev/mhi_QMI0`
3. Service should auto-start: `systemctl status cellular-data-connection.service`
4. Verify IP: `ip addr | grep 192.0.0`

### "Reboot killed my SSH connection"

**This is normal**. After reboot:
1. Tailscale reconnects within 30 seconds
2. Modem will be in bootloader (no cellular)
3. Use Tailscale to connect and power-cycle modem

```bash
# From your local machine:
tailscale ssh dan7554@rpicam2.local

# From Pi, power-cycle modem USB, then:
ssh dan7554@100.68.44.43  # Reconnect via Tailscale
```

### "Service won't start automatically"

Check service dependencies:
```bash
sudo systemctl status cellular-data-connection.service
# Look for "Requires=sim8262a-qmi.service"

# Manually start:
sudo systemctl start cellular-data-connection.service
sudo systemctl status cellular-data-connection.service

# Check logs:
journalctl -u cellular-data-connection.service -n 30
```

### "Modem detected but no IP"

```bash
# Check modem is operational:
lsmod | grep mhi
dmesg | grep "ee:AMSS"  # Should see AMSS mode, not PBL

# Manually start connection:
sudo waveshare-CM -s 3gnet

# Check result:
ip addr | grep rmnet_mhi0.1
ping 8.8.8.8
```

## Important Notes

⚠️ **Remember:**
- **Primary access:** Tailscale VPN (always use this)
- **Backup access:** Cellular (requires power cycle after reboot)
- **Reboots need planning:** Modem goes offline, restore with USB power cycle
- **Tailscale is your safety net:** You can always SSH in via VPN

✅ **This is intentional design**, not a bug:
- Industrial 5G modems require full power cycles to re-initialize
- This is expected behavior across all cellular modems
- System is still fully accessible via Tailscale at all times
- Cellular connectivity is a bonus, not the primary access method

