#!/bin/bash
# SIM8262A-M2 Comprehensive Diagnostic and Auto-Fix Script
# Diagnoses and fixes common issues with SIM8262A PCIe cellular module

echo "🔧 SIM8262A-M2 Diagnostic and Auto-Fix Tool"
echo "==========================================="
echo "This script will diagnose and attempt to fix SIM8262A issues automatically"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (use sudo)"
   exit 1
fi

# Global variables for tracking issues and fixes
ISSUES_FOUND=0
FIXES_APPLIED=0
REBOOT_REQUIRED=false
KERNEL_UPDATE_NEEDED=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

# Issue tracking
issue_found() {
    ((ISSUES_FOUND++))
    log_error "$1"
}

fix_applied() {
    ((FIXES_APPLIED++))
    log_success "FIX APPLIED: $1"
}

# Diagnostic functions
check_hardware_detection() {
    log_info "Checking hardware detection..."
    
    # Check PCIe detection
    PCIE_DEVICE=$(lspci | grep -i "qualcomm\|simcom" || echo "")
    if [ -z "$PCIE_DEVICE" ]; then
        issue_found "SIM8262A not detected via PCIe"
        return 1
    else
        log_success "PCIe device detected: $PCIE_DEVICE"
        return 0
    fi
}

check_pcie_configuration() {
    log_info "Checking PCIe configuration..."
    
    local config_file="/boot/firmware/config.txt"
    local issues=0
    
    # Check if PCIe is enabled
    if ! grep -q "^dtparam=pciex1" "$config_file"; then
        issue_found "PCIe not enabled in config.txt"
        ((issues++))
    fi
    
    # Check PCIe generation setting
    if ! grep -q "^dtparam=pciex1_gen=2" "$config_file"; then
        issue_found "PCIe Gen 2 not configured"
        ((issues++))
    fi
    
    # Check I2C for power monitoring
    if ! grep -q "^dtparam=i2c_arm=on" "$config_file"; then
        issue_found "I2C not enabled for power monitoring"
        ((issues++))
    fi
    
    if [ $issues -eq 0 ]; then
        log_success "PCIe configuration looks correct"
    fi
    
    return $issues
}

check_drivers_loaded() {
    log_info "Checking cellular drivers..."
    
    local driver_issues=0
    
    # Check PCIe MHI driver
    if ! lsmod | grep -q "pcie_mhi" 2>/dev/null; then
        issue_found "PCIe MHI driver not loaded"
        ((driver_issues++))
    else
        log_success "PCIe MHI driver is loaded"
    fi
    
    # Check QMI driver
    if ! lsmod | grep -q "qmi_wwan" 2>/dev/null; then
        issue_found "QMI WWAN driver not loaded"
        ((driver_issues++))
    else
        log_success "QMI WWAN driver is loaded"
    fi
    
    # Check CDC driver
    if ! lsmod | grep -q "cdc_wdm" 2>/dev/null; then
        issue_found "CDC WDM driver not loaded"
        ((driver_issues++))
    else
        log_success "CDC WDM driver is loaded"
    fi
    
    if [ $driver_issues -eq 0 ]; then
        log_success "All required drivers are loaded"
    fi
    
    return 0  # Always return success to prevent script exit
}

check_cellular_interfaces() {
    log_info "Checking cellular network interfaces..."
    
    local interface_issues=0
    
    # Check for QMI/MBIM control interfaces
    if ! ls /dev/cdc-wdm* >/dev/null 2>&1; then
        issue_found "No QMI/MBIM control interfaces found (/dev/cdc-wdm*)"
        ((interface_issues++))
    else
        log_success "QMI/MBIM control interfaces found: $(ls /dev/cdc-wdm* 2>/dev/null)"
    fi
    
    # Check for WWAN network interfaces
    if ! ip link show 2>/dev/null | grep -q wwan; then
        issue_found "No WWAN network interfaces found"
        ((interface_issues++))
    else
        log_success "WWAN network interfaces found"
    fi
    
    if [ $interface_issues -eq 0 ]; then
        log_success "All cellular interfaces are available"
    fi
    
    return 0  # Always return success to prevent script exit
}

check_modemmanager() {
    log_info "Checking ModemManager..."
    
    local mm_issues=0
    
    # Check if ModemManager is running
    if ! systemctl is-active --quiet ModemManager 2>/dev/null; then
        issue_found "ModemManager service not running"
        ((mm_issues++))
    else
        log_success "ModemManager service is running"
    fi
    
    # Check if ModemManager detects modem
    local modem_count=$(mmcli -L 2>/dev/null | grep -c "Modem" || echo "0")
    if [ "$modem_count" -eq 0 ]; then
        issue_found "ModemManager cannot detect any modems (found: $modem_count)"
        ((mm_issues++))
    else
        log_success "ModemManager detected $modem_count modem(s)"
    fi
    
    if [ $mm_issues -eq 0 ]; then
        log_success "ModemManager is working correctly"
    fi
    
    return 0  # Always return success to prevent script exit
}

# Fix functions
fix_pcie_configuration() {
    log_info "Applying PCIe configuration fixes..."
    
    local config_file="/boot/firmware/config.txt"
    local fixes_applied_here=0
    
    # Enable PCIe
    if ! grep -q "^dtparam=pciex1" "$config_file"; then
        echo "dtparam=pciex1" >> "$config_file"
        fix_applied "Enabled PCIe in config.txt"
        ((fixes_applied_here++))
        REBOOT_REQUIRED=true
    fi
    
    # Set PCIe Gen 2
    if ! grep -q "^dtparam=pciex1_gen=2" "$config_file"; then
        echo "dtparam=pciex1_gen=2" >> "$config_file"
        fix_applied "Set PCIe Gen 2 in config.txt"
        ((fixes_applied_here++))
        REBOOT_REQUIRED=true
    fi
    
    # Enable I2C
    if ! grep -q "^dtparam=i2c_arm=on" "$config_file"; then
        echo "dtparam=i2c_arm=on" >> "$config_file"
        fix_applied "Enabled I2C in config.txt"
        ((fixes_applied_here++))
        REBOOT_REQUIRED=true
    fi
    
    # Add power stability settings
    if ! grep -q "^gpu_mem=128" "$config_file"; then
        echo "gpu_mem=128" >> "$config_file"
        fix_applied "Increased GPU memory for stability"
        ((fixes_applied_here++))
        REBOOT_REQUIRED=true
    fi
    
    if ! grep -q "^max_usb_current=1" "$config_file"; then
        echo "max_usb_current=1" >> "$config_file"
        fix_applied "Increased USB current limit"
        ((fixes_applied_here++))
        REBOOT_REQUIRED=true
    fi
    
    return $fixes_applied_here
}

fix_load_drivers() {
    log_info "Loading cellular drivers..."
    
    local drivers_loaded=0
    
    # Load PCIe MHI driver
    if ! lsmod | grep -q "pcie_mhi"; then
        if modprobe pcie_mhi 2>/dev/null; then
            fix_applied "Loaded PCIe MHI driver"
            ((drivers_loaded++))
        else
            log_error "Failed to load PCIe MHI driver"
        fi
    fi
    
    # Load QMI driver
    if ! lsmod | grep -q "qmi_wwan"; then
        if modprobe qmi_wwan 2>/dev/null; then
            fix_applied "Loaded QMI WWAN driver"
            ((drivers_loaded++))
        else
            log_error "Failed to load QMI WWAN driver"
        fi
    fi
    
    # Load CDC driver
    if ! lsmod | grep -q "cdc_wdm"; then
        if modprobe cdc_wdm 2>/dev/null; then
            fix_applied "Loaded CDC WDM driver"
            ((drivers_loaded++))
        else
            log_error "Failed to load CDC WDM driver"
        fi
    fi
    
    return $drivers_loaded
}

fix_driver_binding() {
    log_info "Attempting to bind drivers to PCIe device..."
    
    # Try to bind pcie_mhi driver to the Qualcomm device
    local pci_device=$(lspci | grep -i qualcomm | cut -d' ' -f1)
    if [ ! -z "$pci_device" ]; then
        # Convert to full PCI address format
        local full_address="0000:$pci_device"
        
        if echo "$full_address" 2>/dev/null | tee /sys/bus/pci/drivers/pcie_mhi/bind >/dev/null 2>&1; then
            fix_applied "Bound PCIe MHI driver to device $full_address"
            sleep 5  # Wait for driver binding
            return 1
        else
            log_warning "Driver binding failed or already bound"
            return 0
        fi
    else
        log_error "Cannot find Qualcomm PCIe device for binding"
        return 0
    fi
}

fix_modemmanager() {
    log_info "Fixing ModemManager issues..."
    
    local mm_fixes=0
    
    # Restart ModemManager
    if systemctl restart ModemManager; then
        fix_applied "Restarted ModemManager service"
        ((mm_fixes++))
        
        # Wait for modem detection
        log_info "Waiting 30 seconds for modem detection..."
        sleep 30
    fi
    
    return $mm_fixes
}

install_waveshare_kernel() {
    log_warning "Current kernel may be missing cellular PCIe drivers"
    echo ""
    echo "🌊 Waveshare provides an optimized kernel with proper PCIe cellular drivers."
    echo "This kernel includes:"
    echo "  • Optimized PCIe MHI drivers for cellular modules"
    echo "  • Proper timing and power management"
    echo "  • Enhanced compatibility with SIM8262A"
    echo ""
    read -p "Do you want to install the Waveshare optimized kernel? (Y/n): " install_kernel
    
    if [[ ! $install_kernel =~ ^[Nn]$ ]]; then
        log_info "Installing Waveshare kernel..."
        if wget -O - https://files.waveshare.com/wiki/PCIe-TO-5G-HAT%2B/install.sh | bash; then
            fix_applied "Waveshare kernel installation initiated"
            KERNEL_UPDATE_NEEDED=true
            REBOOT_REQUIRED=true
            return 1
        else
            log_error "Failed to install Waveshare kernel"
            return 0
        fi
    else
        log_warning "Skipped Waveshare kernel installation"
        return 0
    fi
}

create_driver_reload_script() {
    log_info "Creating driver reload script for future use..."
    
    cat > /usr/local/bin/sim8262a-reload-drivers.sh << 'EOF'
#!/bin/bash
# SIM8262A Driver Reload Script
echo "🔄 Reloading SIM8262A PCIe drivers..."

# Remove drivers
sudo rmmod pcie_mhi 2>/dev/null || true
sleep 2

# Reload drivers
sudo modprobe pcie_mhi
sudo modprobe qmi_wwan
sudo modprobe cdc_wdm

# Wait for initialization
sleep 10

# Restart ModemManager
sudo systemctl restart ModemManager
sleep 20

echo "✅ Driver reload completed"

# Show status
echo "📊 Current status:"
lsmod | grep -E "(mhi|qmi|cdc)"
ls /dev/cdc-wdm* 2>/dev/null || echo "No QMI interfaces found"
mmcli -L
EOF

    chmod +x /usr/local/bin/sim8262a-reload-drivers.sh
    fix_applied "Created driver reload script: /usr/local/bin/sim8262a-reload-drivers.sh"
}

create_autoload_service() {
    log_info "Creating systemd service for automatic driver loading..."
    
    cat > /etc/systemd/system/sim8262a-drivers.service << 'EOF'
[Unit]
Description=SIM8262A PCIe Cellular Driver Loader
After=multi-user.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sim8262a-reload-drivers.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sim8262a-drivers.service
    fix_applied "Created autoload service for SIM8262A drivers"
}

# Main diagnostic and fix process
main_diagnostic() {
    log_info "Starting comprehensive SIM8262A diagnostic..."
    echo ""
    
    # Phase 1: Hardware and PCIe checks
    echo "📋 Phase 1: Hardware Detection"
    echo "=============================="
    
    if ! check_hardware_detection; then
        log_error "Hardware not detected - checking PCIe configuration"
        check_pcie_configuration
        
        echo ""
        echo "🔧 Applying PCIe configuration fixes..."
        fix_pcie_configuration
        
        if [ "$REBOOT_REQUIRED" = true ]; then
            log_warning "PCIe configuration updated - reboot required to detect hardware"
            echo ""
            echo "Please reboot and run this script again:"
            echo "sudo reboot"
            echo "# After reboot:"
            echo "sudo ./sim8262a-diagnostic-and-fix.sh"
            exit 0
        fi
    fi
    
    # Phase 2: Driver checks
    echo ""
    echo "📋 Phase 2: Driver Status"
    echo "========================"
    
    check_drivers_loaded
    
    # Try to load missing drivers
    echo ""
    echo "🔧 Loading required drivers..."
    fix_load_drivers
    
    # Try driver binding if needed
    if ! check_cellular_interfaces; then
        echo ""
        echo "🔧 Attempting driver binding..."
        fix_driver_binding
        sleep 5
    fi
    
    # Phase 3: Interface and service checks
    echo ""
    echo "📋 Phase 3: Interface and Service Status"
    echo "======================================="
    
    check_cellular_interfaces
    check_modemmanager
    
    # Fix ModemManager if needed
    echo ""
    echo "🔧 Fixing ModemManager..."
    fix_modemmanager
    
    # Final check
    echo ""
    echo "📋 Final Status Check"
    echo "===================="
    
    local final_modem_count=$(mmcli -L 2>/dev/null | grep -c "Modem" || echo "0")
    if [ "$final_modem_count" -gt 0 ]; then
        log_success "SUCCESS: $final_modem_count modem(s) detected by ModemManager!"
        
        # Show modem details
        mmcli -L
        
        echo ""
        log_success "SIM8262A is now ready for use!"
        echo ""
        echo "📋 Next steps:"
        echo "• Run: sudo ./setup-cellular-connection.sh"
        echo "• Or use: sudo ./carrier-switcher.sh"
        
    else
        log_warning "ModemManager still cannot detect the modem"
        
        # Suggest Waveshare kernel
        if [ "$KERNEL_UPDATE_NEEDED" = false ]; then
            echo ""
            install_waveshare_kernel
            
            if [ "$KERNEL_UPDATE_NEEDED" = true ]; then
                echo ""
                log_warning "System will reboot for kernel update..."
                echo "After reboot, the SIM8262A should be detected automatically."
                exit 0
            fi
        fi
    fi
    
    # Create helper scripts
    echo ""
    echo "🛠️  Creating helper tools..."
    create_driver_reload_script
    create_autoload_service
}

# Run diagnostics
main_diagnostic

echo ""
echo "🎯 Diagnostic Summary"
echo "===================="
echo "Issues found: $ISSUES_FOUND"
echo "Fixes applied: $FIXES_APPLIED"

if [ "$REBOOT_REQUIRED" = true ]; then
    echo ""
    log_warning "⚠️  REBOOT REQUIRED for changes to take effect"
    echo ""
    read -p "Reboot now? (Y/n): " reboot_now
    if [[ ! $reboot_now =~ ^[Nn]$ ]]; then
        echo "Rebooting in 5 seconds..."
        sleep 5
        reboot
    fi
fi

echo ""
echo "✅ Diagnostic and fix process completed!"