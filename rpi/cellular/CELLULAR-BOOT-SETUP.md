# Waveshare SIM8262A-M2 5G HAT+ Boot Configuration - FINAL SOLUTION

## DIP Switch Configuration (CRITICAL!)

The DIP switches on the Waveshare HAT must be set correctly for proper modem operation:

**Required Setting:**
- **RST Switch: OPEN** (UP position) - Enables GPIO5 reset control  
- **PWR Switch: CLOSED** (DOWN position) - Uses automatic power management

**Without correct DIP switch settings:**
- Modem may not enumerate on PCIe bus
- QMI devices won't be created
- Cellular connection will not work
- GPIO control will be non-functional

---

## Boot Sequence Overview

The modem requires proper initialization during boot:

1. **Kernel boots** - PCIe bus initializes
2. **pcie_mhi driver loads** - Detects Qualcomm device (17cb:0308)
3. **MHI devices created** - /dev/mhi_BHI, /dev/mhi_QMI0, etc.
4. **waveshare-CM starts** - Establishes cellular data connection
5. **Tailscale connects** - Secure VPN access ready

---

## Installation Steps

### 1. Verify DIP Switch Settings
- Check physical switches on HAT: RST=OPEN, PWR=CLOSED
- If not correct, adjust and reboot

### 2. Install Cellular Service
```bash
sudo cp rpi/cellular-data-connection.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable cellular-data-connection.service
```

### 3. Verify Installation
```bash
# Check MHI devices exist
ls -la /dev/mhi_*

# Reboot to test
sudo reboot

# After reboot, check connectivity
ip addr show rmnet_mhi0
ping 8.8.8.8
```

---

## Testing Manual Cellular Connection

To test the connection manually without rebooting:

```bash
# Kill existing connection
sudo killall waveshare-CM 2>/dev/null

# Start new connection
sudo waveshare-CM -s 3gnet

# Check in another terminal
tailscale status
ip addr show rmnet_mhi0
```

---

## Troubleshooting

### Modem not detected
- ✅ Check DIP switch settings (RST=OPEN, PWR=CLOSED)
- ✅ Power cycle the entire system (full reboot)
- ✅ Check `sudo lspci` for device 17cb:0308

### No QMI devices
- ✅ Verify MHI driver loaded: `lsmod | grep pcie_mhi`
- ✅ Wait 5-10 seconds after boot before checking
- ✅ Check dmesg: `dmesg | grep -i mhi`

### No internet after connection
- ✅ Check interface: `ip addr show rmnet_mhi0.1`
- ✅ Check routing: `ip route`
- ✅ Try pinging: `ping -I rmnet_mhi0.1 8.8.8.8`

### Cellular works but Tailscale doesn't
- ✅ Check Tailscale status: `tailscale status`
- ✅ Restart Tailscale: `sudo systemctl restart tailscaled`
- ✅ Verify WiFi is not primary route (can disconnect it)

---

## Remote Access Options

### Option 1: Via Tailscale (Recommended)
```bash
ssh dan7554@100.68.44.43  # RPi Tailscale IP
```

### Option 2: Via Public Cellular IP
```bash
# Get current public IP
curl -s https://ifconfig.io --interface rmnet_mhi0.1

# SSH to public IP (requires port forwarding or public key setup)
ssh dan7554@<public-ip>
```

### Option 3: Via Tailscale-SSH (Interactive)
```bash
./tailscale-ssh.sh  # Uses interactive selection of Tailscale devices
```

---

## Current Status

✅ **Modem**: Qualcomm SIM8262A-M2 detected and operational  
✅ **Driver**: pcie_mhi loaded (Quectel proprietary MHI driver v1.3.6)  
✅ **QMI Devices**: /dev/mhi_QMI0, /dev/mhi_DIAG, /dev/mhi_DUN created  
✅ **Network**: rmnet_mhi0 with IP 192.0.0.2  
✅ **Internet**: Connected via T-Mobile (5G NSA)  
✅ **Public IP**: 174.162.192.174 (cellular public address)  
✅ **Tailscale**: Connected at 100.68.44.43  
✅ **SSH Access**: Available via Tailscale from anywhere

---

## Files Created/Modified

- `rpi/cellular-data-connection.service` - Systemd service for auto-connection
- `rpi/modem-gpio-init.sh` - GPIO initialization (archived, not needed with correct DIP switches)
- `rpi/modem-reset-init.service` - Reset initialization (archived, not needed with correct DIP switches)

## Key Discovery

**The DIP switch configuration is the KEY to everything working.** With DIP switches set correctly (RST=OPEN, PWR=CLOSED), the modem boots reliably and no GPIO manipulation scripts are needed. The kernel's pcie_mhi driver handles all the initialization automatically.
