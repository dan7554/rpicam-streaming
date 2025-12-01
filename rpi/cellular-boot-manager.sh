#!/bin/bash

# Cellular Boot Manager for SIM8262A-M2
# Ensures reliable cellular connectivity on every boot
# This script creates services and configurations for automatic cellular initialization

set -e

LOGFILE="/var/log/cellular-boot-manager.log"
SERVICE_NAME="cellular-boot-manager"
QMI_SERVICE_NAME="sim8262a-qmi"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOGFILE"
}

print_header() {
    print_status $BLUE "\n🔧 Cellular Boot Manager Setup"
    print_status $BLUE "================================"
}

# Function to create the boot-time cellular initialization script
create_cellular_init_script() {
    print_status $BLUE "📱 Creating cellular initialization script..."
    
    cat > /usr/local/bin/cellular-init.sh << 'CELLULAR_INIT_EOF'
#!/bin/bash

# Cellular Initialization Script for SIM8262A-M2
# Runs at boot to ensure cellular modem is properly configured

LOGFILE="/var/log/cellular-init.log"
MAX_RETRIES=10
RETRY_DELAY=15
HOME_DIR="/home/dan7554"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

wait_for_pcie_device() {
    local retries=0
    log_message "🔍 Waiting for SIM8262A PCIe device..."
    
    while [ $retries -lt $MAX_RETRIES ]; do
        if lspci | grep -q "Qualcomm"; then
            log_message "✅ PCIe device detected"
            return 0
        fi
        
        retries=$((retries + 1))
        log_message "⏳ Waiting for PCIe device... ($retries/$MAX_RETRIES)"
        sleep $RETRY_DELAY
    done
    
    log_message "❌ PCIe device not detected after $MAX_RETRIES attempts"
    return 1
}

initialize_modem() {
    log_message "🔧 Initializing SIM8262A modem (Quectel MHI driver with proper timing)..."
    
    # Step 1: Reload Quectel MHI driver with proper timing
    log_message "🔄 Reloading Quectel MHI driver..."
    modprobe -r pcie_mhi 2>/dev/null || true
    sleep 3
    modprobe pcie_mhi || true
    sleep 10  # Increased wait time for driver initialization
    
    # Step 2: Check if basic MHI devices were created
    local basic_wait=0
    while [ $basic_wait -lt 6 ]; do
        if [ -c "/dev/mhi_BHI" ]; then
            log_message "✅ Basic MHI devices created"
            break
        fi
        log_message "⏳ Waiting for basic MHI devices... ($basic_wait/6)"
        sleep 5
        basic_wait=$((basic_wait + 1))
    done
    
    if [ ! -c "/dev/mhi_BHI" ]; then
        log_message "❌ Basic MHI devices not found after driver reload"
        return 1
    fi
    
    # Step 3: Wait additional time for all MHI channels to initialize
    log_message "⏳ Waiting for MHI channel initialization..."
    sleep 15
    
    # Step 4: Run multiple attempts to get all MHI devices
    local mhi_attempts=0
    while [ $mhi_attempts -lt 3 ]; do
        log_message "🔧 Attempt $((mhi_attempts + 1)): Checking for all MHI devices..."
        
        # List current devices for debugging
        local current_devices=$(ls /dev/mhi_* 2>/dev/null | wc -l)
        log_message "📋 Found $current_devices MHI devices: $(ls /dev/mhi_* 2>/dev/null | tr '\n' ' ')"
        
        # If we have QMI device, we're good
        if [ -c "/dev/mhi_QMI0" ]; then
            log_message "✅ QMI device found, initialization successful"
            return 0
        fi
        
        # Try restarting services to trigger device creation
        if [ $mhi_attempts -eq 1 ]; then
            log_message "🔄 Restarting ModemManager to trigger device creation..."
            systemctl restart ModemManager
            sleep 10
        fi
        
        mhi_attempts=$((mhi_attempts + 1))
        sleep 10
    done
    
    # Step 5: If still no QMI device, run advanced QMI fix as fallback
    if [ ! -c "/dev/mhi_QMI0" ] && [ -f "$HOME_DIR/advanced-qmi-fix.sh" ]; then
        log_message "🔧 Running advanced QMI fix as fallback..."
        cd "$HOME_DIR" && ./advanced-qmi-fix.sh >> "$LOGFILE" 2>&1
        sleep 10
        
        if [ -c "/dev/mhi_QMI0" ]; then
            log_message "✅ QMI device created via advanced fix"
            return 0
        fi
    fi
    
    return 1
}

wait_for_mhi_devices() {
    local retries=0
    log_message "🔍 Waiting for MHI devices (Quectel driver)..."
    
    while [ $retries -lt 8 ]; do  # Increased retries for Quectel driver
        # Check for multiple MHI devices that indicate full initialization
        if [ -c "/dev/mhi_QMI0" ] && [ -c "/dev/mhi_DIAG" ] && [ -c "/dev/mhi_DUN" ]; then
            log_message "✅ All MHI devices ready (QMI0, DIAG, DUN)"
            log_message "📋 Available devices: $(ls /dev/mhi_* 2>/dev/null | tr '\n' ' ')"
            return 0
        elif [ -c "/dev/mhi_QMI0" ]; then
            log_message "⚠️ QMI device found, waiting for others..."
        fi
        
        retries=$((retries + 1))
        log_message "⏳ Waiting for MHI devices... ($retries/8)"
        sleep 3
    done
    
    # Check if at least QMI device is available
    if [ -c "/dev/mhi_QMI0" ]; then
        log_message "⚠️ Only QMI device ready, but proceeding..."
        return 0
    fi
    
    log_message "❌ MHI devices not ready after initialization"
    return 1
}

configure_modem() {
    log_message "🔧 Final modem configuration..."
    
    # Run ModemManager fix if available
    if [ -f "$HOME_DIR/fix-modemmanager-sim8262a.sh" ]; then
        log_message "🔧 Fixing ModemManager configuration..."
        cd "$HOME_DIR" && ./fix-modemmanager-sim8262a.sh >> "$LOGFILE" 2>&1
    fi
    
    # Restart services
    log_message "🔄 Restarting ModemManager and NetworkManager..."
    systemctl restart ModemManager
    systemctl restart NetworkManager
    
    sleep 10
    
    return 0
}

establish_qmi_connection() {
    local retries=0
    log_message "📱 Establishing QMI connection..."
    
    while [ $retries -lt $MAX_RETRIES ]; do
        if [ -f "$HOME_DIR/qmi-connection-manager.sh" ]; then
            log_message "🚀 Starting QMI connection manager..."
            cd "$HOME_DIR" && ./qmi-connection-manager.sh start >> "$LOGFILE" 2>&1
            
            # Check if connection is successful
            sleep 5
            if ip route | grep -q "rmnet_mhi0"; then
                log_message "✅ QMI connection established"
                
                # Test internet connectivity
                if ping -c 3 -I rmnet_mhi0 8.8.8.8 >> "$LOGFILE" 2>&1; then
                    log_message "✅ Cellular internet connectivity verified"
                    return 0
                else
                    log_message "⚠️ QMI connected but internet test failed"
                fi
            fi
        fi
        
        retries=$((retries + 1))
        log_message "🔄 Retrying QMI connection... ($retries/$MAX_RETRIES)"
        sleep $RETRY_DELAY
    done
    
    log_message "❌ Failed to establish QMI connection after $MAX_RETRIES attempts"
    return 1
}

configure_routing() {
    log_message "🛤️ Configuring cellular routing..."
    
    # Ensure rmnet_mhi0 is up
    if ip link show rmnet_mhi0 >/dev/null 2>&1; then
        ip link set rmnet_mhi0 up
        log_message "✅ rmnet_mhi0 interface brought up"
        
        # Add default route with appropriate metric
        if ! ip route | grep -q "default.*rmnet_mhi0"; then
            # Use a metric that's lower than WiFi but higher than wired
            ip route add default dev rmnet_mhi0 metric 200 || true
            log_message "🛤️ Added default route via cellular"
        fi
        
        # Show final routing table
        log_message "📊 Current routing table:"
        ip route >> "$LOGFILE" 2>&1
    fi
}

restart_tailscale() {
    log_message "🔵 Restarting Tailscale after cellular setup..."
    
    if systemctl is-enabled tailscaled >/dev/null 2>&1; then
        systemctl restart tailscaled
        sleep 5
        
        # Try to bring Tailscale up
        if command -v tailscale >/dev/null 2>&1; then
            tailscale up --ssh --accept-routes --timeout=30s >> "$LOGFILE" 2>&1 || true
            log_message "🔵 Tailscale restart completed"
        fi
    fi
}

# Main initialization sequence
main() {
    log_message "🚀 Starting cellular initialization with proper timing..."
    
    # Wait for hardware to be ready
    if ! wait_for_pcie_device; then
        log_message "❌ PCIe device not ready - aborting"
        exit 1
    fi
    
    # Initialize modem with proper timing and retries
    local init_attempts=0
    while [ $init_attempts -lt 2 ]; do
        log_message "🔧 Initialization attempt $((init_attempts + 1))/2..."
        
        if initialize_modem; then
            log_message "✅ Modem initialization successful"
            break
        else
            log_message "❌ Modem initialization attempt $((init_attempts + 1)) failed"
            init_attempts=$((init_attempts + 1))
            
            if [ $init_attempts -lt 2 ]; then
                log_message "⏳ Waiting 30 seconds before retry..."
                sleep 30
            fi
        fi
    done
    
    if [ $init_attempts -eq 2 ]; then
        log_message "❌ All modem initialization attempts failed - aborting"
        exit 1
    fi
    
    # Wait for MHI devices after initialization
    if ! wait_for_mhi_devices; then
        log_message "❌ MHI devices not ready after initialization - aborting"
        exit 1
    fi
    
    # Final modem configuration
    configure_modem
    
    # Establish connection with retries
    local conn_attempts=0
    while [ $conn_attempts -lt 3 ]; do
        log_message "📱 Connection attempt $((conn_attempts + 1))/3..."
        
        if establish_qmi_connection; then
            log_message "✅ Cellular connection established"
            configure_routing
            restart_tailscale
            log_message "🎉 Cellular initialization complete"
            exit 0
        else
            log_message "❌ Connection attempt $((conn_attempts + 1)) failed"
            conn_attempts=$((conn_attempts + 1))
            
            if [ $conn_attempts -lt 3 ]; then
                log_message "⏳ Waiting 15 seconds before retry..."
                sleep 15
            fi
        fi
    done
    
    log_message "❌ Failed to establish cellular connection after all attempts"
    exit 1
}

# Run main function
main
CELLULAR_INIT_EOF

    chmod +x /usr/local/bin/cellular-init.sh
    print_status $GREEN "✅ Cellular initialization script created"
}

# Function to create systemd service for boot-time initialization
create_systemd_service() {
    print_status $BLUE "⚙️ Creating systemd service for cellular boot management..."
    
    cat > /etc/systemd/system/${SERVICE_NAME}.service << SERVICE_EOF
[Unit]
Description=Cellular Boot Manager for SIM8262A-M2
After=network.target ModemManager.service NetworkManager.service
Wants=network.target ModemManager.service NetworkManager.service
Before=tailscaled.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cellular-init.sh
RemainAfterExit=yes
TimeoutStartSec=300
RestartSec=60
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    # Reload systemd and enable the service
    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}.service
    
    print_status $GREEN "✅ Systemd service created and enabled"
}

# Function to create a more robust QMI service
create_improved_qmi_service() {
    print_status $BLUE "🔧 Creating improved QMI service..."
    
    cat > /etc/systemd/system/${QMI_SERVICE_NAME}.service << QMI_SERVICE_EOF
[Unit]
Description=SIM8262A-M2 QMI Connection Service
After=cellular-boot-manager.service network.target
Wants=cellular-boot-manager.service network.target
Requires=cellular-boot-manager.service

[Service]
Type=forking
ExecStart=/home/dan7554/qmi-connection-manager.sh start
ExecStop=/home/dan7554/qmi-connection-manager.sh stop
ExecReload=/home/dan7554/qmi-connection-manager.sh restart
PIDFile=/var/run/qmi-connection.pid
Restart=on-failure
RestartSec=30
TimeoutStartSec=120
TimeoutStopSec=30
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
QMI_SERVICE_EOF

    # Enable the improved QMI service
    systemctl daemon-reload
    systemctl enable ${QMI_SERVICE_NAME}.service
    
    print_status $GREEN "✅ Improved QMI service created"
}

# Function to create boot-time diagnostics
create_boot_diagnostics() {
    print_status $BLUE "🔍 Creating boot-time diagnostics..."
    
    cat > /usr/local/bin/cellular-boot-check.sh << 'BOOT_CHECK_EOF'
#!/bin/bash

# Boot-time cellular diagnostics
LOGFILE="/var/log/cellular-boot-check.log"

echo "🔍 Cellular Boot Diagnostics - $(date)" | tee -a "$LOGFILE"
echo "========================================" | tee -a "$LOGFILE"

# Check PCIe devices
echo "📋 PCIe Devices:" | tee -a "$LOGFILE"
lspci | grep -i qualcomm | tee -a "$LOGFILE" || echo "❌ No Qualcomm PCIe device found" | tee -a "$LOGFILE"

# Check MHI devices
echo -e "\n📋 MHI Devices:" | tee -a "$LOGFILE"
ls -la /dev/mhi_* 2>/dev/null | tee -a "$LOGFILE" || echo "❌ No MHI devices found" | tee -a "$LOGFILE"

# Check network interfaces
echo -e "\n📋 Network Interfaces:" | tee -a "$LOGFILE"
ip link show | grep -E "(rmnet|wlan|eth)" | tee -a "$LOGFILE"

# Check ModemManager
echo -e "\n📋 ModemManager:" | tee -a "$LOGFILE"
systemctl is-active ModemManager | tee -a "$LOGFILE"
mmcli -L 2>/dev/null | tee -a "$LOGFILE" || echo "❌ No modems detected" | tee -a "$LOGFILE"

# Check services
echo -e "\n📋 Cellular Services:" | tee -a "$LOGFILE"
systemctl is-active cellular-boot-manager | tee -a "$LOGFILE"
systemctl is-active sim8262a-qmi | tee -a "$LOGFILE"

# Check routing
echo -e "\n📋 Routing Table:" | tee -a "$LOGFILE"
ip route | tee -a "$LOGFILE"

echo -e "\n✅ Boot diagnostics complete" | tee -a "$LOGFILE"
BOOT_CHECK_EOF

    chmod +x /usr/local/bin/cellular-boot-check.sh
    print_status $GREEN "✅ Boot diagnostics script created"
}

# Function to create network priority configuration
create_network_priority_config() {
    print_status $BLUE "🔧 Configuring network interface priorities..."
    
    # Create NetworkManager configuration for proper interface priorities
    mkdir -p /etc/NetworkManager/conf.d
    
    cat > /etc/NetworkManager/conf.d/cellular-priority.conf << 'PRIORITY_EOF'
# Cellular network priority configuration
[connection-cellular]
match-device=interface-name:rmnet_mhi0
ethernet.auto-negotiate=false
ipv4.route-metric=200
ipv6.route-metric=200

[connection-wifi]
match-device=interface-name:wlan0
ipv4.route-metric=600
ipv6.route-metric=600

[device-ethernet]
match-device=interface-name:eth0
ipv4.route-metric=100
ipv6.route-metric=100
PRIORITY_EOF

    print_status $GREEN "✅ Network priority configuration created"
}

# Function to create cellular connection watchdog
create_cellular_watchdog() {
    print_status $BLUE "🐕 Creating cellular connection watchdog..."
    
    cat > /usr/local/bin/cellular-watchdog.sh << 'WATCHDOG_EOF'
#!/bin/bash

# Cellular Connection Watchdog
# Monitors and maintains cellular connectivity

LOGFILE="/var/log/cellular-watchdog.log"
CHECK_INTERVAL=60
MAX_FAILURES=3
FAILURE_COUNT=0

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

check_cellular_connection() {
    # Check if rmnet_mhi0 interface exists and has IP
    if ip addr show rmnet_mhi0 | grep -q "inet "; then
        # Test internet connectivity via cellular
        if ping -c 2 -I rmnet_mhi0 -W 10 8.8.8.8 >/dev/null 2>&1; then
            return 0  # Success
        fi
    fi
    return 1  # Failure
}

restart_cellular_connection() {
    log_message "🔄 Restarting cellular connection..."
    
    # Stop QMI connection
    if [ -f "/home/dan7554/qmi-connection-manager.sh" ]; then
        /home/dan7554/qmi-connection-manager.sh stop >> "$LOGFILE" 2>&1
        sleep 5
    fi
    
    # Restart services
    systemctl restart ModemManager
    sleep 10
    
    # Restart QMI connection
    if [ -f "/home/dan7554/qmi-connection-manager.sh" ]; then
        /home/dan7554/qmi-connection-manager.sh start >> "$LOGFILE" 2>&1
        sleep 10
    fi
    
    # Restart Tailscale if it's enabled
    if systemctl is-enabled tailscaled >/dev/null 2>&1; then
        systemctl restart tailscaled
        sleep 5
        tailscale up --ssh --accept-routes --timeout=30s >/dev/null 2>&1 || true
    fi
}

main() {
    log_message "🐕 Cellular watchdog started"
    
    while true; do
        if check_cellular_connection; then
            if [ $FAILURE_COUNT -gt 0 ]; then
                log_message "✅ Cellular connection recovered"
                FAILURE_COUNT=0
            fi
        else
            FAILURE_COUNT=$((FAILURE_COUNT + 1))
            log_message "❌ Cellular connection check failed ($FAILURE_COUNT/$MAX_FAILURES)"
            
            if [ $FAILURE_COUNT -ge $MAX_FAILURES ]; then
                log_message "🚨 Maximum failures reached, restarting cellular connection"
                restart_cellular_connection
                FAILURE_COUNT=0
            fi
        fi
        
        sleep $CHECK_INTERVAL
    done
}

main
WATCHDOG_EOF

    chmod +x /usr/local/bin/cellular-watchdog.sh
    
    # Create watchdog service
    cat > /etc/systemd/system/cellular-watchdog.service << 'WATCHDOG_SERVICE_EOF'
[Unit]
Description=Cellular Connection Watchdog
After=cellular-boot-manager.service sim8262a-qmi.service
Wants=cellular-boot-manager.service sim8262a-qmi.service

[Service]
Type=simple
ExecStart=/usr/local/bin/cellular-watchdog.sh
Restart=always
RestartSec=60
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
WATCHDOG_SERVICE_EOF

    systemctl daemon-reload
    systemctl enable cellular-watchdog.service
    
    print_status $GREEN "✅ Cellular watchdog created and enabled"
}

# Function to create management script
create_management_script() {
    print_status $BLUE "📋 Creating cellular management script..."
    
    cat > /home/dan7554/cellular-manager.sh << 'MANAGER_EOF'
#!/bin/bash

# Cellular Manager Script
# Provides easy management of cellular connectivity

show_help() {
    echo "📱 Cellular Manager for SIM8262A-M2"
    echo "===================================="
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  status       Show cellular connection status"
    echo "  start        Start cellular connection"
    echo "  stop         Stop cellular connection"
    echo "  restart      Restart cellular connection"
    echo "  diagnose     Run comprehensive diagnostics"
    echo "  logs         Show recent cellular logs"
    echo "  enable       Enable cellular auto-start on boot"
    echo "  disable      Disable cellular auto-start on boot"
    echo "  test         Test cellular internet connectivity"
    echo "  help         Show this help message"
}

show_status() {
    echo "📱 Cellular Connection Status"
    echo "============================="
    
    # Check services
    echo ""
    echo "🔧 Services:"
    echo "  Boot Manager: $(systemctl is-active cellular-boot-manager)"
    echo "  QMI Service:  $(systemctl is-active sim8262a-qmi)"
    echo "  Watchdog:     $(systemctl is-active cellular-watchdog)"
    
    # Check interface
    echo ""
    echo "🌐 Network Interface:"
    if ip addr show rmnet_mhi0 >/dev/null 2>&1; then
        IP=$(ip addr show rmnet_mhi0 | grep "inet " | awk '{print $2}' | head -1)
        if [ -n "$IP" ]; then
            echo "  rmnet_mhi0: ✅ UP - $IP"
        else
            echo "  rmnet_mhi0: ⚠️ UP but no IP assigned"
        fi
    else
        echo "  rmnet_mhi0: ❌ Interface not found"
    fi
    
    # Check routing
    echo ""
    echo "🛤️ Routing:"
    if ip route | grep -q rmnet_mhi0; then
        echo "  ✅ Cellular route configured"
        ip route | grep rmnet_mhi0 | head -2
    else
        echo "  ❌ No cellular routes found"
    fi
    
    # Check connectivity
    echo ""
    echo "🌍 Internet Connectivity:"
    if ping -c 2 -I rmnet_mhi0 -W 10 8.8.8.8 >/dev/null 2>&1; then
        echo "  ✅ Internet reachable via cellular"
    else
        echo "  ❌ Internet not reachable via cellular"
    fi
}

start_cellular() {
    echo "🚀 Starting cellular connection..."
    sudo systemctl start cellular-boot-manager
    sudo systemctl start sim8262a-qmi
    echo "✅ Cellular services started"
}

stop_cellular() {
    echo "🛑 Stopping cellular connection..."
    sudo systemctl stop sim8262a-qmi
    echo "✅ Cellular services stopped"
}

restart_cellular() {
    echo "🔄 Restarting cellular connection..."
    stop_cellular
    sleep 5
    start_cellular
}

run_diagnostics() {
    echo "🔍 Running cellular diagnostics..."
    sudo /usr/local/bin/cellular-boot-check.sh
}

show_logs() {
    echo "📋 Recent Cellular Logs"
    echo "======================"
    echo ""
    echo "🔧 Boot Manager:"
    journalctl -u cellular-boot-manager -n 20 --no-pager
    echo ""
    echo "📱 QMI Service:"
    journalctl -u sim8262a-qmi -n 20 --no-pager
}

enable_autostart() {
    echo "🔧 Enabling cellular auto-start on boot..."
    sudo systemctl enable cellular-boot-manager
    sudo systemctl enable sim8262a-qmi
    sudo systemctl enable cellular-watchdog
    echo "✅ Cellular auto-start enabled"
}

disable_autostart() {
    echo "🔧 Disabling cellular auto-start on boot..."
    sudo systemctl disable cellular-boot-manager
    sudo systemctl disable sim8262a-qmi
    sudo systemctl disable cellular-watchdog
    echo "✅ Cellular auto-start disabled"
}

test_connection() {
    echo "🧪 Testing cellular internet connectivity..."
    
    if ! ip addr show rmnet_mhi0 >/dev/null 2>&1; then
        echo "❌ rmnet_mhi0 interface not found"
        return 1
    fi
    
    echo "📍 Testing DNS resolution..."
    if ping -c 1 -I rmnet_mhi0 8.8.8.8 >/dev/null 2>&1; then
        echo "✅ DNS/ICMP working"
    else
        echo "❌ DNS/ICMP failed"
    fi
    
    echo "📍 Testing HTTP connectivity..."
    if curl -s --interface rmnet_mhi0 --max-time 10 http://httpbin.org/ip >/dev/null 2>&1; then
        echo "✅ HTTP working"
        PUBLIC_IP=$(curl -s --interface rmnet_mhi0 --max-time 10 http://httpbin.org/ip | jq -r '.origin' 2>/dev/null || echo "unknown")
        echo "🌍 Public IP: $PUBLIC_IP"
    else
        echo "❌ HTTP failed"
    fi
}

# Main script logic
case "${1:-help}" in
    status)
        show_status
        ;;
    start)
        start_cellular
        ;;
    stop)
        stop_cellular
        ;;
    restart)
        restart_cellular
        ;;
    diagnose)
        run_diagnostics
        ;;
    logs)
        show_logs
        ;;
    enable)
        enable_autostart
        ;;
    disable)
        disable_autostart
        ;;
    test)
        test_connection
        ;;
    help|*)
        show_help
        ;;
esac
MANAGER_EOF

    chmod +x /home/dan7554/cellular-manager.sh
    chown dan7554:dan7554 /home/dan7554/cellular-manager.sh
    
    print_status $GREEN "✅ Cellular manager script created"
}

# Function to modify existing complete-mobile-setup.sh
update_complete_setup() {
    print_status $BLUE "🔧 Updating complete mobile setup script..."
    
    # Add call to cellular boot manager at the end of cellular setup
    if [ -f "/home/dan7554/complete-mobile-setup.sh" ]; then
        # Add boot manager setup call if not already present
        if ! grep -q "cellular-boot-manager" /home/dan7554/complete-mobile-setup.sh; then
            cat >> /home/dan7554/complete-mobile-setup.sh << 'COMPLETE_SETUP_EOF'

# Setup boot-time cellular management
print_status $BLUE "🔧 Setting up boot-time cellular management..."
if [ -f "$SCRIPT_DIR/cellular-boot-manager.sh" ]; then
    bash "$SCRIPT_DIR/cellular-boot-manager.sh" >> "$LOGFILE" 2>&1 || true
    print_status $GREEN "✅ Boot-time cellular management configured"
else
    print_status $YELLOW "⚠️ cellular-boot-manager.sh not found"
fi
COMPLETE_SETUP_EOF
        fi
        
        print_status $GREEN "✅ Complete setup script updated"
    else
        print_status $YELLOW "⚠️ complete-mobile-setup.sh not found"
    fi
}

# Main execution
main() {
    print_header
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        print_status $RED "❌ This script must be run as root (use sudo)"
        exit 1
    fi
    
    print_status $BLUE "🚀 Setting up cellular boot management system..."
    
    create_cellular_init_script
    create_systemd_service
    create_improved_qmi_service
    create_boot_diagnostics
    create_network_priority_config
    create_cellular_watchdog
    create_management_script
    update_complete_setup
    
    print_status $GREEN "✅ Cellular boot manager setup complete!"
    print_status $BLUE ""
    print_status $BLUE "📋 What was configured:"
    print_status $BLUE "   • Boot-time cellular initialization service"
    print_status $BLUE "   • Improved QMI connection service"
    print_status $BLUE "   • Network interface priority configuration"
    print_status $BLUE "   • Cellular connection watchdog"
    print_status $BLUE "   • Boot diagnostics and logging"
    print_status $BLUE "   • Management script: /home/dan7554/cellular-manager.sh"
    print_status $BLUE ""
    print_status $BLUE "🚀 Next steps:"
    print_status $BLUE "   1. Reboot the system: sudo reboot"
    print_status $BLUE "   2. Check status: /home/dan7554/cellular-manager.sh status"
    print_status $BLUE "   3. View logs: journalctl -u cellular-boot-manager"
    print_status $BLUE ""
    print_status $YELLOW "💡 The cellular connection will now automatically establish on every boot!"
}

main "$@"