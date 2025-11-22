# SIM8262A-M2 5G Module Setup for Raspberry Pi 5

## ⚠️ Important Power Requirements

The SIM8262A-M2 is a high-power 5G module that requires adequate power supply:

- **Minimum Power**: 5V 5A (25W) power supply
- **Red LED Status**: Red LED indicates power but may need higher current
- **Insufficient Power Symptoms**:
  - Red LED on but module not detected via USB
  - Module not enumerating in `lsusb`
  - Intermittent connectivity issues

## 🔧 Hardware Setup Checklist

1. **Power Supply**: Use official Raspberry Pi 5V 5A power adapter or equivalent
2. **M.2 Connection**: Ensure SIM8262A-M2 is properly seated in M.2 Key-B slot
3. **SIM Card**: Insert Verizon SIM card into module before first boot
4. **Antennas**: Connect both main and diversity antennas for optimal performance

## 📋 Setup Scripts

### 1. Hardware Diagnostic (Run First)
```bash
sudo ./rpi/sim8262a-diagnostic.sh
```
This script checks:
- Power supply status
- USB device detection
- System health
- Hardware connection issues

### 2. Module Configuration
```bash
sudo ./rpi/configure-5g-modem.sh
```
This script:
- Installs required software (ModemManager, NetworkManager)
- Configures USB mode switching
- Sets up automatic modem detection
- Creates monitoring tools

### 3. Verizon Network Setup
```bash
sudo ./rpi/setup-verizon-5g.sh
```
This script:
- Creates Verizon 5G connection profile
- Configures APN settings (vzwinternet)
- Optimizes settings for SIM8262A-M2
- Enables auto-connection

### 4. Connection Management
```bash
# Check modem status
sudo ./rpi/modem-manager.sh check

# Connect to network
sudo ./rpi/modem-manager.sh connect

# Check connection status
sudo ./rpi/modem-manager.sh status

# Disconnect
sudo ./rpi/modem-manager.sh disconnect
```

## 🔍 Troubleshooting

### Module Not Detected
1. **Check Power**: Ensure 5V 5A power supply
2. **Hardware**: Reseat M.2 module
3. **USB Enumeration**: Run `lsusb | grep 1e0e`
4. **Kernel Messages**: Check `dmesg | grep usb`

### Red LED but No USB Detection
- This is typically a power issue
- Upgrade to higher capacity power supply
- Check all connections are secure
- Try without SIM card initially

### Connection Issues
1. **Signal**: Check antenna connections
2. **APN**: Verify Verizon APN settings
3. **SIM**: Ensure SIM is activated and has data plan
4. **ModemManager**: Check logs with `journalctl -u ModemManager -f`

## 📊 Monitoring Commands

```bash
# List all modems
mmcli -L

# Get modem details
mmcli -m 0

# Check SIM status
mmcli -m 0 --sim=0

# Monitor signal strength
mmcli -m 0 --signal-get

# Network status
nmcli device status

# Connection details
nmcli connection show Verizon5G

# Real-time monitoring
watch -n 2 'mmcli -m 0 --signal-get'
```

## 🌐 Network Verification

```bash
# Test connectivity
ping -c 4 8.8.8.8

# Check routing
ip route

# Speed test (install speedtest-cli first)
speedtest-cli

# Interface status
ip addr show wwan0
```

## 📝 Configuration Files

- USB Mode Switch: `/etc/usb_modeswitch.d/1e0e:*`
- Udev Rules: `/etc/udev/rules.d/40-usb_modeswitch.rules`
- Network Connection: NetworkManager profile "Verizon5G"
- Monitoring Script: `/usr/local/bin/check-modem-status`

## ⚡ Power Optimization

For stable operation:
1. Use quality 5V 5A power supply
2. Avoid USB power from other devices
3. Ensure adequate cooling
4. Monitor for thermal throttling: `vcgencmd get_throttled`

## 🔧 Advanced Configuration

### Manual APN Configuration
If automatic setup doesn't work:
```bash
nmcli connection modify Verizon5G gsm.apn "vzwinternet"
nmcli connection modify Verizon5G gsm.username ""
nmcli connection modify Verizon5G gsm.password ""
```

### 5G Band Selection (if supported)
```bash
# Check available bands
mmcli -m 0 --command="AT+QNWCFG=\"nr5g_band\""

# Set specific bands (example for Verizon)
mmcli -m 0 --command="AT+QNWCFG=\"nr5g_band\",2,5,48,77"
```

## 📞 Support

If issues persist:
1. Check Verizon SIM compatibility
2. Verify data plan includes 5G/LTE access
3. Test SIM in another device
4. Contact SIMCom support for hardware issues