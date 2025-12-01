#!/bin/bash

# Configuration
PI_USER="dan7554"
PI_HOST_WIFI="192.168.50.96"  # WiFi hostname
PI_HOST_TAILSCALE="100.80.96.23"  # Tailscale IP (rpicam2)
PI_HOST_IP="192.168.50.96"  # WiFi static IP (fallback)

# Default to WiFi SSH
PI_HOST="$PI_HOST_TAILSCALE"
CONNECTION_TYPE="tailscale"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --tailscale)
            PI_HOST="$PI_HOST_TAILSCALE"
            CONNECTION_TYPE="tailscale"
            shift
            ;;
        --wifi)
            PI_HOST="$PI_HOST_WIFI"
            CONNECTION_TYPE="wifi"
            shift
            ;;
        --ip)
            PI_HOST="$PI_HOST_IP"
            CONNECTION_TYPE="ip"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--wifi|--tailscale|--ip]"
            echo "  --wifi       SSH over WiFi (rpicam2.local) - DEFAULT"
            echo "  --tailscale  SSH over Tailscale VPN (100.68.44.43)"
            echo "  --ip         SSH over static IP (192.168.50.96)"
            exit 1
            ;;
    esac
done

# Use SSH keys for authentication
SCP_CMD="scp"
SSH_CMD="ssh"

echo "📡 Connection Type: $CONNECTION_TYPE"
echo "🎯 Target Host: $PI_HOST"
echo ""

echo "Copying files to Raspberry Pi..."
# RPi camera streaming files
eval $SCP_CMD rpi/install.sh $PI_USER@$PI_HOST:/home/dan7554/
eval $SCP_CMD rpi/logs.sh $PI_USER@$PI_HOST:/home/dan7554/
eval $SCP_CMD rpi/stop.sh $PI_USER@$PI_HOST:/home/dan7554/
eval $SCP_CMD rpi/start.sh $PI_USER@$PI_HOST:/home/dan7554/
eval $SCP_CMD rpi/rpicam-stream.sh $PI_USER@$PI_HOST:/home/dan7554/
eval $SCP_CMD rpi/rpicam-stream.service $PI_USER@$PI_HOST:/home/dan7554/
eval $SCP_CMD rpi/wifi-switcher.sh $PI_USER@$PI_HOST:/home/dan7554/

# SIM8262A-M2 5G modem scripts (DISABLED)
# eval $SCP_CMD rpi/enable-pcie.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/configure-5g-modem.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/setup-cellular-connection.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/modem-manager.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/carrier-switcher.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/sim8262a-diagnostic.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/sim8262a-summary.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/sim8262a-diagnostic-and-fix.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/waveshare-sim8262a-setup.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/sim8262a-mode-config.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/README-SIM8262A.md $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/fix-rmnet-connection.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/test-verizon-sim.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/test-roaming-connection.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/network-switcher.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/extract-sim-info.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/test-mintmobile-sim.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/fix-qmi-transport.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/fix-modemmanager-sim8262a.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/advanced-qmi-fix.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/cellular-routing-fix.sh $PI_USER@$PI_HOST:/home/dan7554/

# Remote access scripts (Tailscale & backup tunnel)
eval $SCP_CMD rpi/setup-tailscale.sh $PI_USER@$PI_HOST:/home/dan7554/
eval $SCP_CMD rpi/reverse-ssh-tunnel.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/complete-mobile-setup.sh $PI_USER@$PI_HOST:/home/dan7554/
# eval $SCP_CMD rpi/cellular-boot-manager.sh $PI_USER@$PI_HOST:/home/dan7554/


echo "Installing and starting service..."
eval $SSH_CMD $PI_USER@$PI_HOST << 'EOF'
# Make RPi camera script executable
chmod +x /home/dan7554/rpicam-stream.sh

# Make all SIM8262A scripts executable (DISABLED)
# chmod +x /home/dan7554/enable-pcie.sh
# chmod +x /home/dan7554/configure-5g-modem.sh
# chmod +x /home/dan7554/setup-cellular-connection.sh
# chmod +x /home/dan7554/modem-manager.sh
# chmod +x /home/dan7554/carrier-switcher.sh
# chmod +x /home/dan7554/sim8262a-diagnostic.sh
# chmod +x /home/dan7554/sim8262a-summary.sh
# chmod +x /home/dan7554/sim8262a-diagnostic-and-fix.sh
# chmod +x /home/dan7554/waveshare-sim8262a-setup.sh
# chmod +x /home/dan7554/sim8262a-mode-config.sh
# chmod +x /home/dan7554/fix-rmnet-connection.sh
# chmod +x /home/dan7554/test-verizon-sim.sh
# chmod +x /home/dan7554/test-roaming-connection.sh
# chmod +x /home/dan7554/network-switcher.sh
# chmod +x /home/dan7554/extract-sim-info.sh
# chmod +x /home/dan7554/test-mintmobile-sim.sh
# chmod +x /home/dan7554/fix-qmi-transport.sh
# chmod +x /home/dan7554/fix-modemmanager-sim8262a.sh
# chmod +x /home/dan7554/advanced-qmi-fix.sh
# chmod +x /home/dan7554/cellular-routing-fix.sh
# chmod +x /home/dan7554/cellular-boot-manager.sh

chmod +x /home/dan7554/setup-tailscale.sh
chmod +x /home/dan7554/reverse-ssh-tunnel.sh
chmod +x /home/dan7554/complete-mobile-setup.sh
chmod +x /home/dan7554/stop.sh
chmod +x /home/dan7554/wifi-switcher.sh

# Install and start RPi camera service
sudo cp /home/dan7554/rpicam-stream.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable rpicam-stream.service
sudo systemctl start rpicam-stream.service

echo "📹 RPi Camera Service status:"
sudo systemctl status rpicam-stream.service --no-pager

echo ""
echo "📱 SIM8262A-M2 Scripts Summary:"
echo "================================"
echo "Available scripts in /home/dan7554/:"
echo "- enable-pcie.sh                     (Enable PCIe for SIM8262A)"
echo "- sim8262a-diagnostic-and-fix.sh     (🔧 AUTO-DIAGNOSE AND FIX)"
echo "- waveshare-sim8262a-setup.sh        (Waveshare official setup)"
echo "- configure-5g-modem.sh              (Generic modem setup)"
echo "- setup-cellular-connection.sh       (Multi-carrier configuration)"
echo "- carrier-switcher.sh                (Interactive management)"
echo "- sim8262a-mode-config.sh            (PCIe/USB mode config)"
echo "- modem-manager.sh                   (Basic operations)"
echo "- sim8262a-diagnostic.sh             (Hardware diagnostics)"
echo "- sim8262a-summary.sh                (Quick overview)"
echo "- test-verizon-sim.sh                (Verizon testing)"
echo "- test-roaming-connection.sh         (Roaming/eiotclub testing)"
echo "- test-mintmobile-sim.sh             (Mint Mobile testing)"
echo "- fix-qmi-transport.sh               (🔧 Fix QMI/MBIM detection issues)"
echo "- fix-modemmanager-sim8262a.sh       (🆕 Fix ModemManager device recognition)"
echo "- network-switcher.sh                (Switch between WiFi/cellular)"
echo "- extract-sim-info.sh                (Extract SIM activation info)"
echo "- README-SIM8262A.md                 (Complete documentation)"
echo ""
echo "🔵 REMOTE ACCESS SCRIPTS:"
echo "- complete-mobile-setup.sh           (🚀 ONE-CLICK SETUP - Cellular + Tailscale)"
echo "- setup-tailscale.sh                 (🔵 Install Tailscale VPN - FREE)"
echo "- reverse-ssh-tunnel.sh              (🔄 Backup tunnel via VPS)"
echo ""
echo "🌊 RECOMMENDED: Start with Waveshare setup for best compatibility"
echo "📱 Supported Carriers: Verizon, eiotclub/1NCE, Mint Mobile"
echo "Quick start: ./sim8262a-summary.sh"
EOF

echo "Done! Services and SIM8262A scripts installed on Raspberry Pi."
echo ""
echo "🚀 Next Steps:"
echo "1. SSH to your Pi: ssh $PI_USER@$PI_HOST"
echo ""
echo "🎯 QUICK START (recommended):"
echo "2. Complete setup: sudo ./complete-mobile-setup.sh"
echo ""
echo "🔧 OR manual setup:"
echo "2. TRANSPORT FIX: sudo ./advanced-qmi-fix.sh"
echo "3. Or auto-fix: sudo ./sim8262a-diagnostic-and-fix.sh"
echo "4. For Waveshare setup: sudo ./waveshare-sim8262a-setup.sh"
echo "5. Configure carrier: sudo ./setup-cellular-connection.sh"
echo ""
echo "🔵 REMOTE ACCESS SETUP (for mobile network access):"
echo "6. Install Tailscale: sudo ./setup-tailscale.sh"
echo "7. Check connection: ./tailscale-status.sh"
echo "8. Optional backup: ./reverse-ssh-tunnel.sh config"