#!/bin/bash

# Reverse SSH Tunnel Setup Script
# Provides backup remote access when Tailscale is unavailable
# Author: Auto-generated for MediaMTX mobile streaming setup

set -e

LOGFILE="/var/log/reverse-tunnel.log"
VPS_USER="${VPS_USER:-your-user}"
VPS_HOST="${VPS_HOST:-your-vps.com}"
VPS_PORT="${VPS_PORT:-22}"
LOCAL_SSH_PORT="${LOCAL_SSH_PORT:-22}"
REMOTE_PORT="${REMOTE_PORT:-2222}"

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

# Function to check configuration
check_config() {
    echo "🔧 Reverse SSH Tunnel Configuration"
    echo "==================================="
    echo ""
    echo "📋 Current Settings:"
    echo "   VPS User: $VPS_USER"
    echo "   VPS Host: $VPS_HOST"
    echo "   VPS SSH Port: $VPS_PORT"
    echo "   Local SSH Port: $LOCAL_SSH_PORT"
    echo "   Remote Tunnel Port: $REMOTE_PORT"
    echo ""
    
    if [ "$VPS_USER" = "your-user" ] || [ "$VPS_HOST" = "your-vps.com" ]; then
        echo "⚠️  Configuration needed!"
        echo ""
        echo "📝 To configure, set environment variables:"
        echo "   export VPS_USER=\"your-username\""
        echo "   export VPS_HOST=\"your-vps.domain.com\""
        echo "   export VPS_PORT=\"22\"  # Optional, defaults to 22"
        echo "   export REMOTE_PORT=\"2222\"  # Optional, defaults to 2222"
        echo ""
        echo "Example:"
        echo "   export VPS_USER=\"dan\""
        echo "   export VPS_HOST=\"myserver.digitalocean.com\""
        echo "   sudo -E $0 install"
        echo ""
        return 1
    fi
    return 0
}

# Function to generate SSH key if needed
setup_ssh_key() {
    local ssh_dir="/home/dan7554/.ssh"
    local key_file="$ssh_dir/id_reverse_tunnel"
    
    log_message "🔑 Setting up SSH key for reverse tunnel..."
    
    # Ensure .ssh directory exists
    if [ ! -d "$ssh_dir" ]; then
        mkdir -p "$ssh_dir"
        chown dan7554:dan7554 "$ssh_dir"
        chmod 700 "$ssh_dir"
    fi
    
    # Generate key if it doesn't exist
    if [ ! -f "$key_file" ]; then
        log_message "🔐 Generating new SSH key for reverse tunnel..."
        sudo -u dan7554 ssh-keygen -t ed25519 -f "$key_file" -N "" -C "rpicam-reverse-tunnel"
        chmod 600 "$key_file"
        chown dan7554:dan7554 "$key_file" "$key_file.pub"
        
        echo ""
        echo "🔑 SSH Public Key Generated:"
        echo "============================"
        cat "$key_file.pub"
        echo ""
        echo "📋 Next Steps:"
        echo "1. Copy the public key above"
        echo "2. Add it to $VPS_USER@$VPS_HOST:~/.ssh/authorized_keys"
        echo "3. Test connection: ssh -i $key_file $VPS_USER@$VPS_HOST"
        echo "4. Run this script again to create the service"
        echo ""
    else
        log_message "✅ SSH key already exists: $key_file"
    fi
}

# Function to test VPS connection
test_vps_connection() {
    local key_file="/home/dan7554/.ssh/id_reverse_tunnel"
    
    log_message "🧪 Testing VPS connection..."
    
    if sudo -u dan7554 ssh -i "$key_file" -o ConnectTimeout=10 -o BatchMode=yes "$VPS_USER@$VPS_HOST" "echo 'Connection test successful'" 2>/dev/null; then
        log_message "✅ VPS connection successful"
        return 0
    else
        log_message "❌ VPS connection failed"
        echo ""
        echo "🔧 Troubleshooting:"
        echo "1. Ensure the public key is added to $VPS_USER@$VPS_HOST:~/.ssh/authorized_keys"
        echo "2. Check VPS SSH service is running on port $VPS_PORT"
        echo "3. Verify network connectivity to $VPS_HOST"
        echo "4. Test manually: ssh -i /home/dan7554/.ssh/id_reverse_tunnel $VPS_USER@$VPS_HOST"
        return 1
    fi
}

# Function to create systemd service
create_service() {
    local key_file="/home/dan7554/.ssh/id_reverse_tunnel"
    local service_file="/etc/systemd/system/reverse-ssh-tunnel.service"
    
    log_message "📋 Creating reverse SSH tunnel service..."
    
    cat > "$service_file" << EOF
[Unit]
Description=Reverse SSH Tunnel for Remote Access
After=network-online.target tailscaled.service
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=dan7554
ExecStart=/usr/bin/ssh -i $key_file -N -T -R $REMOTE_PORT:localhost:$LOCAL_SSH_PORT -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new $VPS_USER@$VPS_HOST -p $VPS_PORT
ExecStop=/usr/bin/pkill -f "ssh.*$VPS_HOST.*$REMOTE_PORT"
Restart=always
RestartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_message "✅ Service file created: $service_file"
}

# Function to create management script
create_management_script() {
    log_message "📋 Creating tunnel management script..."
    
    cat > /home/dan7554/reverse-tunnel-manager.sh << 'EOF'
#!/bin/bash

# Reverse SSH Tunnel Manager
# Manage the reverse SSH tunnel for backup remote access

SERVICE_NAME="reverse-ssh-tunnel"

case "$1" in
    start)
        echo "🚀 Starting reverse SSH tunnel..."
        sudo systemctl start $SERVICE_NAME
        ;;
    stop)
        echo "⏹️  Stopping reverse SSH tunnel..."
        sudo systemctl stop $SERVICE_NAME
        ;;
    restart)
        echo "🔄 Restarting reverse SSH tunnel..."
        sudo systemctl restart $SERVICE_NAME
        ;;
    status)
        echo "📊 Reverse SSH Tunnel Status:"
        echo "============================="
        
        # Service status
        if systemctl is-active --quiet $SERVICE_NAME; then
            echo "✅ Service: Running"
        else
            echo "❌ Service: Stopped"
        fi
        
        # Check if tunnel is actually working
        TUNNEL_PID=$(pgrep -f "ssh.*$VPS_HOST.*2222" 2>/dev/null || echo "")
        if [ -n "$TUNNEL_PID" ]; then
            echo "✅ Tunnel: Active (PID: $TUNNEL_PID)"
        else
            echo "❌ Tunnel: Not connected"
        fi
        
        # Recent logs
        echo ""
        echo "📋 Recent Logs:"
        sudo journalctl -u $SERVICE_NAME --no-pager -n 5
        ;;
    enable)
        echo "🔧 Enabling reverse SSH tunnel auto-start..."
        sudo systemctl enable $SERVICE_NAME
        echo "✅ Auto-start enabled"
        ;;
    disable)
        echo "🔧 Disabling reverse SSH tunnel auto-start..."
        sudo systemctl disable $SERVICE_NAME
        echo "✅ Auto-start disabled"
        ;;
    test)
        echo "🧪 Testing VPS connection..."
        if ssh -i /home/dan7554/.ssh/id_reverse_tunnel -o ConnectTimeout=10 -o BatchMode=yes $VPS_USER@$VPS_HOST "echo 'Test successful'"; then
            echo "✅ Connection test passed"
        else
            echo "❌ Connection test failed"
            echo "Check your VPS configuration and SSH key"
        fi
        ;;
    info)
        echo "📋 Connection Information:"
        echo "========================="
        echo ""
        if systemctl is-active --quiet $SERVICE_NAME && pgrep -f "ssh.*2222" >/dev/null; then
            echo "🌐 Access from anywhere via VPS:"
            echo "   ssh -p 2222 dan7554@$VPS_HOST"
            echo ""
            echo "🔧 VPS Configuration:"
            echo "   User: $VPS_USER"
            echo "   Host: $VPS_HOST"
            echo "   Tunnel Port: 2222"
            echo "   Status: ✅ Active"
        else
            echo "❌ Tunnel not active"
            echo "Run: $0 start"
        fi
        ;;
    *)
        echo "🔧 Reverse SSH Tunnel Manager"
        echo "============================="
        echo ""
        echo "Usage: $0 {start|stop|restart|status|enable|disable|test|info}"
        echo ""
        echo "Commands:"
        echo "  start    - Start the tunnel"
        echo "  stop     - Stop the tunnel"
        echo "  restart  - Restart the tunnel"
        echo "  status   - Show tunnel and service status"
        echo "  enable   - Enable auto-start on boot"
        echo "  disable  - Disable auto-start"
        echo "  test     - Test VPS connection"
        echo "  info     - Show connection details"
        ;;
esac
EOF

    chmod +x /home/dan7554/reverse-tunnel-manager.sh
    chown dan7554:dan7554 /home/dan7554/reverse-tunnel-manager.sh
    log_message "✅ Created tunnel manager: /home/dan7554/reverse-tunnel-manager.sh"
}

# Main function
main() {
    case "$1" in
        install)
            if [[ $EUID -ne 0 ]]; then
                echo "❌ Installation must be run as root (use sudo)"
                exit 1
            fi
            
            log_message "🚀 Installing reverse SSH tunnel..."
            
            if ! check_config; then
                exit 1
            fi
            
            setup_ssh_key
            
            if ! test_vps_connection; then
                echo "❌ Cannot proceed without working VPS connection"
                exit 1
            fi
            
            create_service
            create_management_script
            
            echo ""
            echo "✅ Reverse SSH tunnel installed!"
            echo "================================"
            echo ""
            echo "🔧 Management Commands:"
            echo "   ./reverse-tunnel-manager.sh start     # Start tunnel"
            echo "   ./reverse-tunnel-manager.sh enable    # Auto-start on boot"
            echo "   ./reverse-tunnel-manager.sh status    # Check status"
            echo "   ./reverse-tunnel-manager.sh info      # Show connection details"
            echo ""
            echo "🌐 Once running, access from anywhere:"
            echo "   ssh -p $REMOTE_PORT dan7554@$VPS_HOST"
            ;;
        
        config)
            check_config
            ;;
        
        *)
            echo "🔧 Reverse SSH Tunnel Setup"
            echo "==========================="
            echo ""
            echo "This script sets up a reverse SSH tunnel as backup remote access"
            echo "for when Tailscale is unavailable or blocked."
            echo ""
            echo "📋 Prerequisites:"
            echo "1. A VPS or cloud server with SSH access"
            echo "2. Environment variables configured (see below)"
            echo ""
            echo "🚀 Usage:"
            echo "   $0 config    # Check current configuration"
            echo "   $0 install   # Install tunnel service"
            echo ""
            echo "📝 Configuration (set before install):"
            echo "   export VPS_USER=\"your-username\""
            echo "   export VPS_HOST=\"your-server.com\""
            echo "   export VPS_PORT=\"22\"          # Optional"
            echo "   export REMOTE_PORT=\"2222\"    # Optional"
            echo "   sudo -E $0 install"
            echo ""
            echo "💡 After installation, tunnel creates this access:"
            echo "   ssh -p 2222 dan7554@your-server.com"
            ;;
    esac
}

# Run main function
main "$@"