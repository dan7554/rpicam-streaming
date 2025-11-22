#!/bin/bash

# Smart Connect Script - Intelligent Pi Connection with Tailscale Priority
# Automatically connects to Raspberry Pi using the best available method
# Author: Auto-generated for MediaMTX mobile streaming setup

set -e

# Configuration
PI_USER="dan7554"
PI_WIFI_HOST="rpicam2.local"  # or 192.168.50.96
PI_PASSWORD="!Dan1007554"
CONNECTION_TIMEOUT=10

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to check if sshpass is available
check_sshpass() {
    if [ -n "$PI_PASSWORD" ] && ! command -v sshpass >/dev/null 2>&1; then
        print_status $YELLOW "⚠️  sshpass not found - you'll need to enter password manually"
        return 1
    fi
    return 0
}

# Function to get Tailscale IP from local machine (if available)
get_local_tailscale_status() {
    if command -v tailscale >/dev/null 2>&1; then
        # Get connected devices and look for our Pi
        TAILSCALE_DEVICES=$(tailscale status 2>/dev/null | grep -E "(rpicam|dan7554)" | grep -v "^#" || echo "")
        if [ -n "$TAILSCALE_DEVICES" ]; then
            # Extract IP from first matching device
            echo "$TAILSCALE_DEVICES" | awk '{print $1}' | head -1
        fi
    fi
    echo ""
}

# Function to test SSH connection
test_ssh_connection() {
    local host=$1
    local method=$2
    
    print_status $BLUE "🧪 Testing $method connection to $host..."
    
    if [ -n "$PI_PASSWORD" ] && check_sshpass; then
        if timeout $CONNECTION_TIMEOUT sshpass -p "$PI_PASSWORD" ssh -o ConnectTimeout=$CONNECTION_TIMEOUT -o BatchMode=no -o StrictHostKeyChecking=accept-new "$PI_USER@$host" "echo 'Connection successful'" 2>/dev/null; then
            return 0
        fi
    else
        if timeout $CONNECTION_TIMEOUT ssh -o ConnectTimeout=$CONNECTION_TIMEOUT -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$PI_USER@$host" "echo 'Connection successful'" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Function to connect via SSH
connect_ssh() {
    local host=$1
    local method=$2
    
    print_status $GREEN "🔗 Connecting to Pi via $method ($host)..."
    
    if [ -n "$PI_PASSWORD" ] && check_sshpass; then
        exec sshpass -p "$PI_PASSWORD" ssh "$PI_USER@$host"
    else
        exec ssh "$PI_USER@$host"
    fi
}

# Function to show connection info
show_connection_info() {
    print_status $BLUE "📋 Pi Connection Information"
    print_status $BLUE "============================"
    echo ""
    
    print_status $YELLOW "🎯 Connection Methods (in priority order):"
    echo "   1. 🔵 Tailscale VPN (works from anywhere)"
    echo "   2. 📶 WiFi/Local Network (same network only)"
    echo ""
    
    print_status $YELLOW "🔧 Available Commands:"
    echo "   $0                    # Smart connect (auto-detect best method)"
    echo "   $0 tailscale         # Force Tailscale connection"
    echo "   $0 wifi              # Force WiFi/local connection"
    echo "   $0 test              # Test all connection methods"
    echo "   $0 info              # Show this information"
    echo ""
    
    # Check local Tailscale status
    if command -v tailscale >/dev/null 2>&1; then
        TAILSCALE_STATUS=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "unknown"' 2>/dev/null || echo "unknown")
        case $TAILSCALE_STATUS in
            "Running")
                print_status $GREEN "✅ Local Tailscale: Connected"
                ;;
            "NeedsLogin")
                print_status $YELLOW "🔑 Local Tailscale: Needs authentication"
                echo "   Run: tailscale up"
                ;;
            *)
                print_status $RED "❌ Local Tailscale: Not connected ($TAILSCALE_STATUS)"
                ;;
        esac
    else
        print_status $YELLOW "📦 Tailscale not installed locally"
        echo "   Install: https://tailscale.com/download"
    fi
    echo ""
    
    print_status $YELLOW "🛠️  Pi Setup Commands (run on Pi after connecting):"
    echo "   sudo ./setup-tailscale.sh        # Install Tailscale on Pi"
    echo "   ./tailscale-status.sh            # Check Pi Tailscale status"
    echo "   ./network-switcher.sh status     # Check all network status"
    echo "   ./reverse-tunnel-manager.sh info # Check backup tunnel"
}

# Function to test all methods
test_all_methods() {
    print_status $BLUE "🧪 Testing All Connection Methods"
    print_status $BLUE "=================================="
    echo ""
    
    local success_count=0
    local methods_tested=0
    
    # Test Tailscale connection
    TAILSCALE_IP=$(get_local_tailscale_status)
    if [ -n "$TAILSCALE_IP" ] && [ "$TAILSCALE_IP" != "" ]; then
        methods_tested=$((methods_tested + 1))
        if test_ssh_connection "$TAILSCALE_IP" "Tailscale"; then
            print_status $GREEN "✅ Tailscale ($TAILSCALE_IP): WORKING"
            success_count=$((success_count + 1))
        else
            print_status $RED "❌ Tailscale ($TAILSCALE_IP): FAILED"
        fi
    else
        print_status $YELLOW "⚠️  Tailscale IP not available (Pi may not be connected to Tailscale)"
    fi
    
    # Test WiFi/local connection
    methods_tested=$((methods_tested + 1))
    if test_ssh_connection "$PI_WIFI_HOST" "WiFi/Local"; then
        print_status $GREEN "✅ WiFi/Local ($PI_WIFI_HOST): WORKING"
        success_count=$((success_count + 1))
    else
        print_status $RED "❌ WiFi/Local ($PI_WIFI_HOST): FAILED"
    fi
    
    echo ""
    print_status $BLUE "📊 Test Results: $success_count/$methods_tested methods working"
    
    if [ $success_count -eq 0 ]; then
        print_status $RED "❌ No working connection methods found"
        echo ""
        print_status $YELLOW "🔧 Troubleshooting:"
        echo "   1. Ensure Pi is powered on and booted"
        echo "   2. Check if Pi is on same WiFi network"
        echo "   3. Verify Tailscale is installed and connected on both devices"
        echo "   4. Try: ping $PI_WIFI_HOST"
        echo "   5. Check if SSH is enabled on the Pi"
        return 1
    fi
}

# Function for smart connection (tries methods in order)
smart_connect() {
    print_status $BLUE "🧠 Smart Connect: Finding best connection method..."
    echo ""
    
    # Method 1: Try Tailscale first (works from anywhere)
    TAILSCALE_IP=$(get_local_tailscale_status)
    if [ -n "$TAILSCALE_IP" ] && [ "$TAILSCALE_IP" != "" ]; then
        if test_ssh_connection "$TAILSCALE_IP" "Tailscale"; then
            print_status $GREEN "🎯 Using Tailscale connection"
            connect_ssh "$TAILSCALE_IP" "Tailscale"
            return 0
        fi
    fi
    
    # Method 2: Try WiFi/local network
    if test_ssh_connection "$PI_WIFI_HOST" "WiFi/Local"; then
        print_status $GREEN "🎯 Using WiFi/Local connection"
        connect_ssh "$PI_WIFI_HOST" "WiFi/Local"
        return 0
    fi
    
    # If we get here, nothing worked
    print_status $RED "❌ No working connection methods found"
    echo ""
    print_status $YELLOW "💡 Suggestions:"
    echo "   1. Run '$0 test' to diagnose connection issues"
    echo "   2. Check if Pi is powered on: ping $PI_WIFI_HOST"
    echo "   3. Ensure Tailscale is set up: $0 info"
    echo "   4. Check network connectivity"
    
    return 1
}

# Function to force Tailscale connection
force_tailscale() {
    TAILSCALE_IP=$(get_local_tailscale_status)
    
    if [ -z "$TAILSCALE_IP" ] || [ "$TAILSCALE_IP" = "" ]; then
        print_status $RED "❌ Tailscale IP not found"
        print_status $YELLOW "💡 Make sure:"
        echo "   1. Tailscale is installed locally and on Pi"
        echo "   2. Both devices are connected to same Tailscale network"
        echo "   3. Pi has run: sudo ./setup-tailscale.sh"
        return 1
    fi
    
    if test_ssh_connection "$TAILSCALE_IP" "Tailscale"; then
        connect_ssh "$TAILSCALE_IP" "Tailscale"
    else
        print_status $RED "❌ Tailscale connection failed"
        return 1
    fi
}

# Function to force WiFi connection
force_wifi() {
    if test_ssh_connection "$PI_WIFI_HOST" "WiFi/Local"; then
        connect_ssh "$PI_WIFI_HOST" "WiFi/Local"
    else
        print_status $RED "❌ WiFi/Local connection failed"
        return 1
    fi
}

# Main script logic
main() {
    case "$1" in
        "tailscale"|"ts")
            force_tailscale
            ;;
        "wifi"|"local")
            force_wifi
            ;;
        "test"|"check")
            test_all_methods
            ;;
        "info"|"help"|"-h"|"--help")
            show_connection_info
            ;;
        "")
            # Default: smart connect
            smart_connect
            ;;
        *)
            print_status $RED "❌ Unknown command: $1"
            echo ""
            show_connection_info
            exit 1
            ;;
    esac
}

# Handle Ctrl+C gracefully
trap 'echo ""; print_status $YELLOW "Connection attempt cancelled"; exit 1' INT

# Run main function with all arguments
main "$@"