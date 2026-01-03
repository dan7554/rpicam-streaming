#!/bin/bash

# Complete Mobile Pi Setup Script
# Sets up cellular networking (SIM8262A) + Tailscale remote access
# Author: Auto-generated for MediaMTX mobile streaming setup

set -e  # Exit on any error

LOGFILE="/var/log/mobile-pi-setup.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration flags
SKIP_CELLULAR=false
SKIP_TAILSCALE=false
FORCE_REINSTALL=false

# Function to print colored output
print_status() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOGFILE"
}

print_header() {
    local title=$1
    print_status $CYAN "\n=============================================="
    print_status $CYAN "$title"
    print_status $CYAN "=============================================="
}

print_step() {
    local step=$1
    local description=$2
    print_status $BLUE "\n📍 Step $step: $description"
    print_status $BLUE "$(printf '=%.0s' {1..50})"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_status $RED "❌ This script must be run as root (use sudo)"
        echo ""
        print_status $YELLOW "Usage: sudo $0 [options]"
        echo ""
        print_status $YELLOW "Options:"
        echo "  --skip-cellular    Skip cellular network setup"
        echo "  --skip-tailscale   Skip Tailscale installation"
        echo "  --force           Force reinstallation of components"
        echo "  --help            Show this help message"
        echo ""
        print_status $YELLOW "Examples:"
        echo "  sudo $0                          # Full setup"
        echo "  sudo $0 --skip-cellular         # Tailscale only"
        echo "  sudo $0 --skip-tailscale        # Cellular only"
        echo "  sudo $0 --force                 # Force reinstall everything"
        exit 1
    fi
}

# Function to parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-cellular)
                SKIP_CELLULAR=true
                shift
                ;;
            --skip-tailscale)
                SKIP_TAILSCALE=true
                shift
                ;;
            --force)
                FORCE_REINSTALL=true
                shift
                ;;
            --help|-h)
                check_root  # This will show usage and exit
                ;;
            *)
                print_status $RED "❌ Unknown option: $1"
                check_root  # This will show usage and exit
                ;;
        esac
    done
}

# Function to show setup summary
show_setup_summary() {
    print_header "MOBILE PI SETUP SUMMARY"
    print_status $YELLOW "📋 Configuration:"
    echo "   Cellular Setup: $([ "$SKIP_CELLULAR" = "true" ] && echo "SKIPPED" || echo "ENABLED")"
    echo "   Tailscale Setup: $([ "$SKIP_TAILSCALE" = "true" ] && echo "SKIPPED" || echo "ENABLED")"
    echo "   Force Reinstall: $([ "$FORCE_REINSTALL" = "true" ] && echo "YES" || echo "NO")"
    echo "   Log File: $LOGFILE"
    echo ""
    print_status $BLUE "This will set up your Pi for mobile streaming with remote access"
    echo ""
    read -p "Continue with setup? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status $YELLOW "Setup cancelled by user"
        exit 0
    fi
}

# Function to update system packages
update_system() {
    print_step "1" "System Update & Dependencies"
    
    print_status $BLUE "📦 Updating package lists..."
    apt update >> "$LOGFILE" 2>&1
    
    print_status $BLUE "📦 Installing essential packages..."
    apt install -y \
        curl \
        wget \
        jq \
        netcat-openbsd \
        network-manager \
        modemmanager \
        libqmi-utils \
        udhcpc \
        systemd \
        openssh-server \
        >> "$LOGFILE" 2>&1
    
    print_status $GREEN "✅ System packages updated and dependencies installed"
}

# Function to setup cellular networking
setup_cellular() {
    print_step "2" "Cellular Network Configuration (SIM8262A)"
    
    if [ "$SKIP_CELLULAR" = "true" ]; then
        print_status $YELLOW "⏭️  Cellular setup skipped by user"
        return 0
    fi
    
    # Check if already configured (unless force reinstall)
    if [ "$FORCE_REINSTALL" = "false" ] && command -v mmcli >/dev/null 2>&1; then
        MODEM_COUNT=$(mmcli -L 2>/dev/null | grep -c "Modem" || echo "0")
        if [ "$MODEM_COUNT" -gt 0 ]; then
            print_status $YELLOW "ℹ️  ModemManager already configured with $MODEM_COUNT modem(s)"
            print_status $BLUE "🔍 Checking modem status..."
            mmcli -L 2>/dev/null || true
        else
            print_status $BLUE "🔧 ModemManager installed but no modems detected"
        fi
    fi
    
    # Enable PCIe if needed
    print_status $BLUE "🔧 Enabling PCIe for SIM8262A..."
    if [ -f "$SCRIPT_DIR/enable-pcie.sh" ]; then
        bash "$SCRIPT_DIR/enable-pcie.sh" >> "$LOGFILE" 2>&1 || true
    else
        print_status $YELLOW "⚠️  enable-pcie.sh not found, continuing..."
    fi
    
    # Run diagnostic and fix script first for best results
    print_status $BLUE "🔧 Running comprehensive diagnostic and fix..."
    if [ -f "$SCRIPT_DIR/sim8262a-diagnostic-and-fix.sh" ]; then
        bash "$SCRIPT_DIR/sim8262a-diagnostic-and-fix.sh" >> "$LOGFILE" 2>&1 || {
            print_status $YELLOW "⚠️  Diagnostic script had issues, trying advanced QMI fix..."
            if [ -f "$SCRIPT_DIR/advanced-qmi-fix.sh" ]; then
                bash "$SCRIPT_DIR/advanced-qmi-fix.sh" >> "$LOGFILE" 2>&1 || true
            fi
        }
    else
        print_status $YELLOW "⚠️  Diagnostic script not found, trying alternative fixes..."
        # Fallback to individual fix scripts
        if [ -f "$SCRIPT_DIR/advanced-qmi-fix.sh" ]; then
            print_status $BLUE "🔧 Applying advanced QMI transport fixes..."
            bash "$SCRIPT_DIR/advanced-qmi-fix.sh" >> "$LOGFILE" 2>&1 || true
        fi
        
        if [ -f "$SCRIPT_DIR/fix-modemmanager-sim8262a.sh" ]; then
            print_status $BLUE "🔧 Fixing ModemManager device recognition..."
            bash "$SCRIPT_DIR/fix-modemmanager-sim8262a.sh" >> "$LOGFILE" 2>&1 || true
        fi
    fi
    
    # Run Waveshare setup for best compatibility
    print_status $BLUE "🌊 Running Waveshare SIM8262A setup..."
    if [ -f "$SCRIPT_DIR/waveshare-sim8262a-setup.sh" ]; then
        bash "$SCRIPT_DIR/waveshare-sim8262a-setup.sh" >> "$LOGFILE" 2>&1 || {
            print_status $YELLOW "⚠️  Waveshare setup had issues, applying additional fixes..."
            
            # Try additional fix scripts if Waveshare setup fails
            if [ -f "$SCRIPT_DIR/fix-rmnet-connection.sh" ]; then
                print_status $BLUE "🔧 Fixing rmnet connection issues..."
                bash "$SCRIPT_DIR/fix-rmnet-connection.sh" >> "$LOGFILE" 2>&1 || true
            fi
            
            if [ -f "$SCRIPT_DIR/fix-qmi-transport.sh" ]; then
                print_status $BLUE "🔧 Fixing QMI transport detection..."
                bash "$SCRIPT_DIR/fix-qmi-transport.sh" >> "$LOGFILE" 2>&1 || true
            fi
        }
    else
        print_status $YELLOW "⚠️  Waveshare setup script not found"
        
        # Fallback to generic modem configuration
        if [ -f "$SCRIPT_DIR/configure-5g-modem.sh" ]; then
            print_status $BLUE "🔧 Trying generic 5G modem configuration..."
            bash "$SCRIPT_DIR/configure-5g-modem.sh" >> "$LOGFILE" 2>&1 || true
        fi
    fi
    
    # Configure cellular connection
    print_status $BLUE "📱 Setting up cellular connection..."
    if [ -f "$SCRIPT_DIR/setup-cellular-connection.sh" ]; then
        bash "$SCRIPT_DIR/setup-cellular-connection.sh" >> "$LOGFILE" 2>&1 || {
            print_status $YELLOW "⚠️  Cellular connection setup had issues, trying carrier-specific scripts..."
            
            # Try carrier-specific test scripts if main setup fails
            if [ -f "$SCRIPT_DIR/test-verizon-sim.sh" ]; then
                print_status $BLUE "📱 Testing Verizon SIM configuration..."
                bash "$SCRIPT_DIR/test-verizon-sim.sh" >> "$LOGFILE" 2>&1 || true
            fi
        }
    fi
    
    # Restart services to ensure everything is properly loaded
    print_status $BLUE "🔄 Restarting network services..."
    systemctl restart ModemManager >> "$LOGFILE" 2>&1 || true
    systemctl restart NetworkManager >> "$LOGFILE" 2>&1 || true
    
    # Give services time to initialize
    sleep 10
    
    # Test cellular connectivity
    print_status $BLUE "🧪 Testing cellular connection..."
    sleep 5  # Additional time for connection to establish
    
    # Check if modem is detected
    MODEM_DETECTED=$(mmcli -L 2>/dev/null | grep -c "Modem" || echo "0")
    if [ "$MODEM_DETECTED" -gt 0 ]; then
        print_status $GREEN "✅ SIM8262A modem detected ($MODEM_DETECTED device(s))"
        
        # Show modem details
        mmcli -L >> "$LOGFILE" 2>&1
        
        # Check for active connection
        if ip route | grep -q rmnet_mhi0; then
            CELLULAR_IP=$(ip route get 1.1.1.1 2>/dev/null | grep rmnet_mhi0 | awk '{print $7}' | head -1 || echo "unknown")
            print_status $GREEN "✅ Cellular connection active - IP: $CELLULAR_IP"
            
            # Test internet connectivity via cellular
            if ping -I rmnet_mhi0 -c 2 8.8.8.8 >/dev/null 2>&1; then
                print_status $GREEN "✅ Cellular internet connectivity verified"
            else
                print_status $YELLOW "⚠️  Cellular connected but internet test failed"
            fi
        else
            print_status $YELLOW "⚠️  Modem detected but no active cellular connection"
            print_status $BLUE "💡 You may need to run carrier-specific configuration later"
        fi
    else
        print_status $RED "❌ SIM8262A modem not detected"
        print_status $BLUE "🔧 This could be due to:"
        echo "   • Hardware not properly seated"
        echo "   • Driver/kernel issues"
        echo "   • Need for reboot after PCIe enabling"
        
        # Try one more diagnostic
        if [ -f "$SCRIPT_DIR/sim8262a-diagnostic.sh" ]; then
            print_status $BLUE "🔍 Running additional diagnostics..."
            bash "$SCRIPT_DIR/sim8262a-diagnostic.sh" >> "$LOGFILE" 2>&1 || true
        fi
        
        print_status $YELLOW "💡 After reboot, try: ./sim8262a-summary.sh"
    fi
}

# Function to setup Tailscale
setup_tailscale() {
    print_step "3" "Tailscale VPN Installation & Configuration"
    
    if [ "$SKIP_TAILSCALE" = "true" ]; then
        print_status $YELLOW "⏭️  Tailscale setup skipped by user"
        return 0
    fi
    
    # Check if already installed (unless force reinstall)
    if [ "$FORCE_REINSTALL" = "false" ] && command -v tailscale >/dev/null 2>&1; then
        print_status $YELLOW "ℹ️  Tailscale already installed"
        TAILSCALE_STATUS=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "unknown"' 2>/dev/null || echo "unknown")
        print_status $BLUE "Current status: $TAILSCALE_STATUS"
    else
        print_status $BLUE "📦 Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh >> "$LOGFILE" 2>&1
        print_status $GREEN "✅ Tailscale installed successfully"
    fi
    
    # Start and enable Tailscale service
    print_status $BLUE "🚀 Starting Tailscale service..."
    systemctl enable tailscaled >> "$LOGFILE" 2>&1
    systemctl start tailscaled >> "$LOGFILE" 2>&1
    
    if systemctl is-active --quiet tailscaled; then
        print_status $GREEN "✅ Tailscale service is running"
    else
        print_status $RED "❌ Failed to start Tailscale service"
        return 1
    fi
    
    # Create Tailscale status script
    print_status $BLUE "📋 Creating Tailscale management scripts..."
    cat > /home/dan7554/tailscale-status.sh << 'EOF'
#!/bin/bash

echo "🔵 Tailscale Status Report"
echo "=========================="

if systemctl is-active --quiet tailscaled; then
    echo "✅ Service: Running"
else
    echo "❌ Service: Stopped"
    exit 1
fi

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

TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "unavailable")
CELLULAR_IP=$(ip route get 1.1.1.1 2>/dev/null | grep rmnet_mhi0 | awk '{print $7}' | head -1 || echo "unavailable")
WIFI_IP=$(ip route get 1.1.1.1 2>/dev/null | grep wlan0 | awk '{print $7}' | head -1 || echo "unavailable")

echo ""
echo "📍 Network Information:"
echo "   🔵 Tailscale: $TAILSCALE_IP"
echo "   📱 Cellular:  $CELLULAR_IP"
echo "   📶 WiFi:      $WIFI_IP"

if [ "$TAILSCALE_IP" != "unavailable" ]; then
    echo "$TAILSCALE_IP" > /home/dan7554/.tailscale_ip
fi

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
    
    # Create auto-reconnect service
    print_status $BLUE "🔄 Setting up Tailscale auto-reconnect..."
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

    systemctl daemon-reload >> "$LOGFILE" 2>&1
    systemctl enable tailscale-keepalive.service >> "$LOGFILE" 2>&1
    systemctl start tailscale-keepalive.service >> "$LOGFILE" 2>&1
    
    print_status $GREEN "✅ Tailscale auto-reconnect service configured"
}

# Function to configure SSH optimizations
configure_ssh() {
    print_step "4" "SSH Configuration for Mobile Networks"
    
    print_status $BLUE "🔧 Optimizing SSH for mobile networks..."
    
    if ! grep -q "# Mobile network optimizations" /etc/ssh/sshd_config; then
        cat >> /etc/ssh/sshd_config << 'EOF'

# Mobile network optimizations
ClientAliveInterval 30
ClientAliveCountMax 3
TCPKeepAlive yes
EOF
        systemctl reload ssh >> "$LOGFILE" 2>&1
        print_status $GREEN "✅ SSH optimized for mobile networks"
    else
        print_status $YELLOW "ℹ️  SSH already optimized"
    fi
    
    # Ensure SSH service is enabled
    systemctl enable ssh >> "$LOGFILE" 2>&1
    print_status $GREEN "✅ SSH service enabled"
}

# Function to create management scripts
create_management_scripts() {
    print_step "5" "Creating Management Scripts"
    
    print_status $BLUE "📋 Creating network management script..."
    
    # Create a comprehensive status script
    cat > /home/dan7554/mobile-status.sh << 'EOF'
#!/bin/bash

echo "📱 Mobile Pi Status Dashboard"
echo "=============================="
echo ""

# Tailscale Status
echo "🔵 Tailscale VPN:"
if command -v tailscale >/dev/null 2>&1; then
    STATUS=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "unknown"' 2>/dev/null || echo "unknown")
    IP=$(tailscale ip -4 2>/dev/null || echo "unavailable")
    
    case $STATUS in
        "Running") echo "   ✅ Connected - IP: $IP" ;;
        "NeedsLogin") echo "   🔑 Needs auth - Run: sudo tailscale up --ssh --accept-routes" ;;
        "Stopped") echo "   ⏹️  Stopped" ;;
        *) echo "   ❓ $STATUS" ;;
    esac
else
    echo "   📦 Not installed"
fi

# Cellular Status
echo ""
echo "📱 Cellular Network:"
if ip route | grep -q rmnet_mhi0; then
    CELL_IP=$(ip route get 1.1.1.1 2>/dev/null | grep rmnet_mhi0 | awk '{print $7}' | head -1 || echo "unknown")
    echo "   ✅ Connected - IP: $CELL_IP"
else
    echo "   ❌ Not connected"
fi

# WiFi Status
echo ""
echo "📶 WiFi Network:"
if ip route | grep -q wlan0; then
    WIFI_IP=$(ip route get 1.1.1.1 2>/dev/null | grep wlan0 | awk '{print $7}' | head -1 || echo "unknown")
    echo "   ✅ Connected - IP: $WIFI_IP"
else
    echo "   ❌ Not connected"
fi

# Internet Test
echo ""
echo "🌐 Internet Connectivity:"
if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "   ✅ Working"
    PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "unknown")
    echo "   🌍 Public IP: $PUBLIC_IP"
else
    echo "   ❌ Failed"
fi

echo ""
echo "🛠️  Quick Commands:"
echo "   ./tailscale-status.sh           # Detailed Tailscale info"
echo "   ./network-switcher.sh status    # Network switching options"
echo "   sudo systemctl status tailscaled # Service status"
EOF

    chmod +x /home/dan7554/mobile-status.sh
    chown dan7554:dan7554 /home/dan7554/mobile-status.sh
    
    print_status $GREEN "✅ Management scripts created"
}

# Function to perform final configuration
final_configuration() {
    print_step "6" "Final Configuration & Testing"
    
    # Set proper ownership for user files
    print_status $BLUE "🔧 Setting file permissions..."
    chown -R dan7554:dan7554 /home/dan7554/
    
    # Configure Tailscale (prompt user for auth)
    if [ "$SKIP_TAILSCALE" = "false" ] && command -v tailscale >/dev/null 2>&1; then
        print_status $BLUE "🔑 Configuring Tailscale authentication..."
        echo ""
        print_status $YELLOW "📱 You'll need to authenticate Tailscale in your browser"
        print_status $YELLOW "🌐 The authentication URL will be displayed below"
        print_status $YELLOW "🔗 Visit the URL on any device to authorize this Pi"
        echo ""
        
        if tailscale up --ssh --accept-routes; then
            TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "pending")
            print_status $GREEN "✅ Tailscale configured successfully"
            if [ "$TAILSCALE_IP" != "pending" ]; then
                print_status $GREEN "🎯 Tailscale IP: $TAILSCALE_IP"
                echo "$TAILSCALE_IP" > /home/dan7554/.tailscale_ip
                chown dan7554:dan7554 /home/dan7554/.tailscale_ip
            fi
        else
            print_status $YELLOW "⚠️  Tailscale configuration incomplete (you can complete it later)"
        fi
    fi
    
    print_status $GREEN "✅ Final configuration complete"
}

# Function to show completion summary
show_completion_summary() {
    print_header "🎉 MOBILE PI SETUP COMPLETE!"
    
    echo ""
    print_status $GREEN "✅ Setup Summary:"
    echo "   📱 Cellular Network: $([ "$SKIP_CELLULAR" = "true" ] && echo "SKIPPED" || echo "CONFIGURED")"
    echo "   🔵 Tailscale VPN: $([ "$SKIP_TAILSCALE" = "true" ] && echo "SKIPPED" || echo "INSTALLED")"
    echo "   🔧 SSH Optimized: YES"
    echo "   📋 Management Scripts: CREATED"
    
    echo ""
    print_status $BLUE "🛠️  Available Commands:"
    echo "   ./mobile-status.sh              # Quick status dashboard"
    echo "   ./tailscale-status.sh           # Detailed Tailscale info"
    echo "   ./network-switcher.sh status    # Network status & switching"
    
    if [ "$SKIP_CELLULAR" = "false" ]; then
        echo "   ./sim8262a-summary.sh           # Cellular modem status"
        echo "   ./carrier-switcher.sh           # Manage cellular carriers"
        echo ""
        print_status $YELLOW "🔧 Troubleshooting Commands (if needed):"
        echo "   sudo ./sim8262a-diagnostic-and-fix.sh    # Auto-diagnose and fix issues"
        echo "   sudo ./advanced-qmi-fix.sh               # Fix QMI transport issues"
        echo "   sudo ./fix-modemmanager-sim8262a.sh      # Fix ModemManager recognition"
        echo "   sudo ./waveshare-sim8262a-setup.sh       # Re-run Waveshare setup"
        echo "   ./test-verizon-sim.sh                    # Test Verizon connectivity"
        echo "   ./test-roaming-connection.sh             # Test roaming/eiotclub"
    fi
    
    echo ""
    print_status $YELLOW "🔍 Next Steps:"
    echo "   1. Check status: ./mobile-status.sh"
    
    if [ "$SKIP_CELLULAR" = "false" ]; then
        # Check actual cellular status and provide specific guidance
        if ip route | grep -q rmnet_mhi0; then
            echo "   2. ✅ Cellular working - Test: ./network-switcher.sh cellular"
        else
            echo "   2. ⚠️  Cellular needs attention:"
            echo "      - Check hardware: sudo ./sim8262a-diagnostic.sh"
            echo "      - Try auto-fix: sudo ./sim8262a-diagnostic-and-fix.sh"
            echo "      - Or reboot and run: ./sim8262a-summary.sh"
        fi
    fi
    
    if [ "$SKIP_TAILSCALE" = "false" ]; then
        if command -v tailscale >/dev/null 2>&1; then
            TAILSCALE_STATUS=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "unknown"' 2>/dev/null || echo "unknown")
            if [ "$TAILSCALE_STATUS" = "NeedsLogin" ]; then
                echo "   3. 🔑 Complete Tailscale: sudo tailscale up --ssh --accept-routes"
            elif [ "$TAILSCALE_STATUS" = "Running" ]; then
                TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
                echo "   3. ✅ Tailscale working - IP: $TAILSCALE_IP"
            else
                echo "   3. 🔧 Check Tailscale: ./tailscale-status.sh"
            fi
        fi
    fi
    
    echo "   4. Test remote access from another device"
    
    echo ""
    print_status $CYAN "🌐 Remote Access:"
    if [ "$SKIP_TAILSCALE" = "false" ] && command -v tailscale >/dev/null 2>&1; then
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "complete-setup-first")
        echo "   ssh dan7554@$TAILSCALE_IP  # From anywhere (after Tailscale auth)"
    fi
    echo "   ssh dan7554@rpicam2.local      # From local network"
    
    # Show any critical issues that need attention
    echo ""
    if [ "$SKIP_CELLULAR" = "false" ]; then
        MODEM_COUNT=$(mmcli -L 2>/dev/null | grep -c "Modem" || echo "0")
        if [ "$MODEM_COUNT" -eq 0 ]; then
            print_status $RED "⚠️  ATTENTION: SIM8262A modem not detected"
            echo "   This usually requires a reboot after PCIe configuration"
            echo "   After reboot, run: sudo ./sim8262a-diagnostic-and-fix.sh"
        fi
    fi
    
    echo ""
    print_status $BLUE "📋 Log file: $LOGFILE"
    print_status $GREEN "🎯 Your Pi is now ready for mobile streaming with remote access!"
    
    if [ "$SKIP_CELLULAR" = "false" ] && ! ip route | grep -q rmnet_mhi0; then
        echo ""
        print_status $YELLOW "💡 If cellular isn't working after reboot:"
        echo "   1. Run: ./sim8262a-summary.sh (quick overview)"
        echo "   2. Run: sudo ./sim8262a-diagnostic-and-fix.sh (auto-fix)"
        echo "   3. Check hardware connections and SIM card"
    fi
}

# Main execution function
main() {
    # Initialize log file
    echo "Mobile Pi Setup Started: $(date)" > "$LOGFILE"
    
    parse_args "$@"
    check_root
    show_setup_summary
    
    print_header "🚀 STARTING MOBILE PI SETUP"
    
    update_system
    
    if [ "$SKIP_CELLULAR" = "false" ]; then
        setup_cellular
    fi
    
    if [ "$SKIP_TAILSCALE" = "false" ]; then
        setup_tailscale
    fi
    
    configure_ssh
    create_management_scripts
    final_configuration
    show_completion_summary
}

# Handle Ctrl+C gracefully
trap 'echo ""; print_status $RED "Setup interrupted by user"; exit 1' INT

# Run main function with all arguments
main "$@"