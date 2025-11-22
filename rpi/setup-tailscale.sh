#!/bin/bash

# Tailscale Installation and Configuration Script for Raspberry Pi
# This script sets up secure remote access via Tailscale VPN
# Author: Auto-generated for MediaMTX mobile streaming setup

set -e  # Exit on any error

LOGFILE="/var/log/tailscale-setup.log"

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | sudo tee -a "$LOGFILE"
    echo "$1"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "❌ This script must be run as root (use sudo)"
        echo "Usage: sudo $0"
        exit 1
    fi
}

# Function to install Tailscale
install_tailscale() {
    log_message "📦 Installing Tailscale..."
    
    # Download and install Tailscale
    if curl -fsSL https://tailscale.com/install.sh | sh; then
        log_message "✅ Tailscale installed successfully"
    else
        log_message "❌ Failed to install Tailscale"
        exit 1
    fi
}

# Function to start and enable Tailscale service
start_tailscale_service() {
    log_message "🚀 Starting Tailscale service..."
    
    systemctl enable tailscaled
    systemctl start tailscaled
    
    if systemctl is-active --quiet tailscaled; then
        log_message "✅ Tailscale service is running"
    else
        log_message "❌ Failed to start Tailscale service"
        exit 1
    fi
}

# Function to configure Tailscale
configure_tailscale() {
    log_message "⚙️  Configuring Tailscale..."
    
    echo "🔑 You'll need to authenticate Tailscale in your browser"
    echo "📱 The authentication URL will be displayed below"
    echo "🌐 Visit the URL on any device to authorize this Pi"
    echo ""
    
    # Enable Tailscale with SSH access and accept routes
    if tailscale up --ssh --accept-routes; then
        log_message "✅ Tailscale configured successfully"
        
        # Get Tailscale IP
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "not-available-yet")
        if [ "$TAILSCALE_IP" != "not-available-yet" ]; then
            log_message "🎯 Tailscale IP: $TAILSCALE_IP"
            echo "$TAILSCALE_IP" > /home/dan7554/.tailscale_ip
            chown dan7554:dan7554 /home/dan7554/.tailscale_ip
        else
            log_message "⏳ Tailscale IP not available yet (auth may be pending)"
        fi
    else
        log_message "❌ Failed to configure Tailscale"
        exit 1
    fi
}

# Function to create Tailscale status check script
create_status_script() {
    log_message "📋 Creating Tailscale status script..."
    
    cat > /home/dan7554/tailscale-status.sh << 'EOF'
#!/bin/bash

# Tailscale Status Check Script
echo "🔵 Tailscale Status Report"
echo "=========================="

# Check service status
if systemctl is-active --quiet tailscaled; then
    echo "✅ Service: Running"
else
    echo "❌ Service: Stopped"
    exit 1
fi

# Check connection status
STATUS=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "unknown"' 2>/dev/null || echo "unknown")
case $STATUS in
    "Running")
        echo "✅ Connection: Connected"
        ;;
    "NeedsLogin")
        echo "🔑 Connection: Needs authentication"
        echo "Run: sudo tailscale up --ssh --accept-routes"
        ;;
    "Stopped")
        echo "⏸️  Connection: Stopped"
        echo "Run: sudo tailscale up --ssh --accept-routes"
        ;;
    *)
        echo "❓ Connection: $STATUS"
        ;;
esac

# Show IP addresses
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "unavailable")
CELLULAR_IP=$(ip route get 1.1.1.1 2>/dev/null | grep rmnet_mhi0 | awk '{print $7}' | head -1 || echo "unavailable")
WIFI_IP=$(ip route get 1.1.1.1 2>/dev/null | grep wlan0 | awk '{print $7}' | head -1 || echo "unavailable")

echo ""
echo "📍 Network Information:"
echo "   🔵 Tailscale: $TAILSCALE_IP"
echo "   📱 Cellular:  $CELLULAR_IP"
echo "   📶 WiFi:      $WIFI_IP"

# Update stored Tailscale IP
if [ "$TAILSCALE_IP" != "unavailable" ]; then
    echo "$TAILSCALE_IP" > /home/dan7554/.tailscale_ip
fi

# Show peers
echo ""
echo "👥 Connected Devices:"
tailscale status 2>/dev/null | grep -v "^#" | head -10 || echo "   (none visible)"

echo ""
echo "🔗 SSH Access Commands:"
if [ "$TAILSCALE_IP" != "unavailable" ]; then
    echo "   ssh dan7554@$TAILSCALE_IP"
else
    echo "   (Tailscale IP unavailable)"
fi
EOF

    chmod +x /home/dan7554/tailscale-status.sh
    chown dan7554:dan7554 /home/dan7554/tailscale-status.sh
    log_message "✅ Created /home/dan7554/tailscale-status.sh"
}

# Function to create auto-reconnect service
create_reconnect_service() {
    log_message "🔄 Creating Tailscale auto-reconnect service..."
    
    # Create systemd service for auto-reconnect
    cat > /etc/systemd/system/tailscale-keepalive.service << 'EOF'
[Unit]
Description=Tailscale Keepalive and Auto-reconnect
After=tailscaled.service
Requires=tailscaled.service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/bash -c 'while true; do sleep 300; if ! tailscale status >/dev/null 2>&1; then logger "Tailscale reconnecting..."; tailscale up --ssh --accept-routes --timeout=60s; fi; done'
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tailscale-keepalive.service
    systemctl start tailscale-keepalive.service
    
    log_message "✅ Auto-reconnect service created and started"
}

# Function to update SSH configuration for better mobile access
configure_ssh() {
    log_message "🔧 Optimizing SSH for mobile networks..."
    
    # Create SSH config optimizations
    if ! grep -q "# Tailscale optimizations" /etc/ssh/sshd_config; then
        cat >> /etc/ssh/sshd_config << 'EOF'

# Tailscale optimizations for mobile networks
ClientAliveInterval 30
ClientAliveCountMax 3
TCPKeepAlive yes
EOF
        systemctl reload ssh
        log_message "✅ SSH optimized for mobile networks"
    else
        log_message "ℹ️  SSH already optimized"
    fi
}

# Main installation function
main() {
    log_message "🚀 Starting Tailscale installation for MediaMTX Pi"
    
    check_root
    
    # Check if already installed
    if command -v tailscale >/dev/null 2>&1; then
        log_message "ℹ️  Tailscale already installed, checking configuration..."
    else
        install_tailscale
    fi
    
    start_tailscale_service
    create_status_script
    configure_ssh
    create_reconnect_service
    
    echo ""
    echo "🎉 Tailscale Setup Complete!"
    echo "============================"
    echo ""
    echo "📋 Next Steps:"
    echo "1. Run: sudo tailscale up --ssh --accept-routes"
    echo "2. Visit the authentication URL in your browser"
    echo "3. Check status: ./tailscale-status.sh"
    echo "4. From any device: ssh dan7554@<tailscale-ip>"
    echo ""
    echo "🔍 Useful Commands:"
    echo "   ./tailscale-status.sh              # Check status"
    echo "   sudo tailscale status              # Show connected devices"
    echo "   sudo tailscale ip                  # Show Tailscale IP"
    echo "   sudo tailscale logout              # Disconnect"
    echo "   sudo systemctl status tailscaled   # Service status"
    echo ""
    
    configure_tailscale
    
    echo ""
    echo "✅ Installation and initial configuration complete!"
    echo "🔵 Run './tailscale-status.sh' to verify everything is working"
}

# Run main function
main "$@"