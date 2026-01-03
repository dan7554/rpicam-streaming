# Troubleshooting Decision Tree

## "I can't access my Pi"

```
┌─ Can you ping the Pi on local network (rpicam2.local)?
│
├─ YES → Go to "SSH Connection Issues"
│
└─ NO ─┐
       ├─ Is Pi powered on? (check lights/monitor)
       │  ├─ NO → Power it on
       │  └─ YES → Continue
       │
       └─ Can you SSH via Tailscale instead?
           ├─ YES → Local network is down, but you're connected!
           │        Problem is not your Pi.
           │        Check your LAN/WiFi/Modem
           │
           └─ NO → Your Pi has a serious problem
                   Try power cycle of the entire Pi
```

## SSH Connection Issues

```
┌─ When you SSH, what error do you get?
│
├─ "Connection refused" → Pi is up but SSH not running
│   └─ Power cycle the entire Pi
│
├─ "Connection timeout" → Can't reach the Pi
│   └─ Use Tailscale instead: ssh dan7554@100.68.44.43
│
├─ "Permission denied (publickey)" → SSH key issue
│   └─ Check your SSH key is correct
│       ssh -i ~/.ssh/id_rsa dan7554@rpicam2.local
│
└─ "Host key verification failed" → Known hosts issue
    └─ Reconnect and accept the key
        ssh-keygen -R rpicam2.local
        ssh dan7554@rpicam2.local
```

## Cellular Not Working After Reboot

```
┌─ Is your modem USB still plugged in?
│
├─ NO → Plug it in and wait 30 seconds
│
└─ YES ─┐
        ├─ Check modem status:
        │  $ ls /dev/mhi_*
        │
        ├─ Only see /dev/mhi_BHI? (no QMI0)
        │  └─ Modem is in bootloader mode (expected after reboot)
        │     Power-cycle USB: unplug 10s, plug in, wait 30s
        │
        ├─ See /dev/mhi_QMI0 and others?
        │  └─ Modem is ready!
        │     Check service: sudo systemctl status cellular-data-connection.service
        │
        └─ Still have issues? 
           See "Cellular Service Troubleshooting" below
```

## Cellular Service Troubleshooting

```
┌─ Check service status:
│  $ sudo systemctl status cellular-data-connection.service
│
├─ Service is "inactive"?
│  └─ Missing QMI device (see above - power cycle modem USB)
│
├─ Service says "active" but no IP?
│  └─ Run manually and check logs:
│     $ sudo waveshare-CM -s 3gnet
│     Watch for errors
│
├─ Service keeps restarting?
│  └─ Check logs:
│     $ journalctl -u cellular-data-connection.service -n 50
│     Look for error messages
│
└─ All else fails?
   └─ Manually restart everything:
      1. Unplug modem USB
      2. Wait 10 seconds
      3. Plug modem USB back in
      4. Wait 30 seconds
      5. Check: $ sudo systemctl status cellular-data-connection.service
```

## Can't Reach Internet Through Cellular

```
┌─ Verify cellular interface has IP:
│  $ ip addr | grep 192.0.0
│
├─ No IP address?
│  └─ Service failed to get DHCP
│     1. Check modem status: $ dmesg | grep ee:
│     2. Should see "ee:AMSS" (if "ee:PBL" → power cycle USB)
│     3. Restart service: $ sudo systemctl restart cellular-data-connection.service
│
├─ Has IP (192.0.0.2)?
│  └─ Verify ping works:
│     $ ping -I rmnet_mhi0.1 8.8.8.8
│
│     ├─ Works? → System is fine, check your network issues
│     │
│     └─ Doesn't work?
│         └─ Routing issue - check:
│            $ ip route | grep rmnet
│            $ route -n
```

## Modem Stuck in Bootloader

```
Symptoms:
  $ dmesg | grep ee:
  Shows: "ee:PBL"
  
  $ ls /dev/mhi_*
  Only shows: /dev/mhi_BHI

Solution:
  1. Unplug modem USB cable from Pi
  2. Count to 10 (complete power loss to modem)
  3. Plug USB back in
  4. Wait 30 seconds for device enumeration
  5. Verify: $ ls /dev/mhi_QMI0
  6. Service should auto-start now
  
Why this happens:
  - Expected after any reboot
  - Modem firmware requires full power cycle to initialize
  - This is normal for cellular modems
```

## Tailscale Connection Lost

```
┌─ Is your local network working?
│
├─ YES → Tailscale should reconnect within 30 seconds
│        If not: $ sudo systemctl restart tailscaled
│
└─ NO ─ Both your network AND Tailscale are down
        └─ You need local access to fix this
           Power cycle everything and try again
```

## Service Won't Auto-Start

```
Check boot-time dependencies:
  $ sudo systemctl status cellular-data-connection.service
  
Look for:
  "Condition not met" → Waiting for dependencies
  
  Fix: Just wait a bit and check again
       System takes time to initialize all services
  
  If it never starts:
  $ journalctl -u cellular-data-connection.service -n 50
  $ journalctl -u sim8262a-qmi.service -n 50
```

## System Is Slow / Stuck

```
Probably the modem is causing issues:
  1. Check dmesg for errors:
     $ dmesg | tail -20
  
  2. If you see mhi driver errors:
     $ dmesg | grep -i mhi | tail -10
  
  3. Nuclear option - disconnect modem:
     - Unplug modem USB
     - System should speed up immediately
     - Check what changed: $ dmesg | tail -10
     - If better: modem USB is the issue
```

## Nothing Works - Emergency Recovery

```
Last resort:

1. Power off the entire Pi:
   - Physical power off (unplug USB)
   - Wait 10 seconds
   
2. Power cycle the modem:
   - Unplug modem USB
   - Wait 10 seconds
   
3. Power on everything:
   - Plug in Pi USB
   - Wait 30 seconds
   - Plug in modem USB
   - Wait 30 seconds
   
4. SSH in and check:
   - Via Tailscale: $ ssh dan7554@100.68.44.43
   - Or local: $ ssh dan7554@rpicam2.local
   
   If Tailscale works: Your modem was the issue
   If SSH works: Restart cellular service:
     $ sudo systemctl restart cellular-data-connection.service
```

---

## Quick Reference

### Most Common Fixes
1. **Cellular not working?** → Power cycle modem USB
2. **Can't SSH?** → Use Tailscale instead
3. **Service not running?** → Check for QMI devices
4. **Pi too slow?** → Unplug modem USB
5. **Everything broken?** → Power cycle everything

### Critical Reminders
⚠️ **Reboots will break cellular** - Use power-cycle instead of reboot for maintenance
⚠️ **Tailscale is your lifeline** - Always use it as primary access
⚠️ **Modem needs USB power** - Make sure USB cable is plugged in
⚠️ **Wait for boot** - Services take time, don't panic immediately

### Commands to Know
```bash
# Check modem status
lspci -d 17cb:0308
ls /dev/mhi_*
dmesg | grep ee:

# Check cellular IP
ip addr | grep 192.0.0

# Check services
sudo systemctl status cellular-data-connection.service
sudo systemctl status tailscaled

# Manual cellular start
sudo waveshare-CM -s 3gnet

# Logs
journalctl -u cellular-data-connection.service -n 20
```

