#!/bin/bash

# Tailscale SSH Manager
# Easily connect to devices in your Tailscale network
# Author: Auto-generated for MediaMTX mobile streaming setup

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to check if Tailscale is installed and running
check_tailscale() {
    if ! command -v tailscale >/dev/null 2>&1; then
        print_status $RED "❌ Tailscale not installed"
        echo ""
        print_status $YELLOW "Install Tailscale:"
        echo "  macOS: brew install tailscale"
        echo "  Linux: curl -fsSL https://tailscale.com/install.sh | sh"
        echo "  Or visit: https://tailscale.com/download"
        exit 1
    fi
    
    local status=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "unknown"' 2>/dev/null || echo "unknown")
    if [ "$status" != "Running" ]; then
        print_status $RED "❌ Tailscale not connected"
        echo ""
        print_status $YELLOW "Connect to Tailscale:"
        echo "  tailscale up"
        exit 1
    fi
}

# Function to parse Tailscale devices
get_tailscale_devices() {
    tailscale status 2>/dev/null | grep -v "^#" | grep -v "^$" | while IFS= read -r line; do
        # Parse tailscale status output
        # Format: IP hostname [extra-hostname-info] user@ OS status
        local ip=$(echo "$line" | awk '{print $1}')
        local hostname=$(echo "$line" | awk '{print $2}')
        
        # Skip invalid entries
        if [[ "$ip" =~ ^100\. ]] && [ -n "$hostname" ]; then
            # Extract everything after the second field for display
            local rest=$(echo "$line" | cut -d' ' -f3- 2>/dev/null || echo "")
            echo "$ip|$hostname|$rest"
        fi
    done
}

# Function to list devices
list_devices() {
    print_status $CYAN "🔵 Tailscale Network Devices"
    print_status $CYAN "============================="
    echo ""
    
    local devices=$(get_tailscale_devices)
    if [ -z "$devices" ]; then
        print_status $YELLOW "No devices found in Tailscale network"
        return 1
    fi
    
    local count=1
    echo "$devices" | while IFS='|' read -r ip hostname rest; do
        printf "%2d. %-15s %-20s %s\n" "$count" "$ip" "$hostname" "$rest"
        count=$((count + 1))
    done
    
    return 0
}

# Function to connect to device by number
connect_by_number() {
    local choice=$1
    local devices=$(get_tailscale_devices)
    
    if [ -z "$devices" ]; then
        print_status $RED "❌ No devices available"
        return 1
    fi
    
    local device_count=$(echo "$devices" | wc -l)
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$device_count" ]; then
        print_status $RED "❌ Invalid choice. Please select 1-$device_count"
        return 1
    fi
    
    local selected=$(echo "$devices" | sed -n "${choice}p")
    local ip=$(echo "$selected" | cut -d'|' -f1)
    local hostname=$(echo "$selected" | cut -d'|' -f2)
    
    print_status $GREEN "🔗 Connecting to $hostname ($ip)..."
    
    # Try SSH with different possible usernames
    local usernames=("dan7554")
    
    for username in "${usernames[@]}"; do
        print_status $BLUE "Trying: ssh $username@$ip"
        if timeout 5 ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$username@$ip" "echo 'Connection successful'" 2>/dev/null; then
            print_status $GREEN "✅ Connected as $username"
            exec ssh "$username@$ip"
            return 0
        fi
    done
    
    # If all usernames fail, try interactive connection
    print_status $YELLOW "⚠️  Automatic username detection failed"
    print_status $BLUE "Trying interactive connection..."
    
    read -p "Enter username for $hostname: " custom_username
    if [ -n "$custom_username" ]; then
        exec ssh "$custom_username@$ip"
    else
        print_status $RED "❌ Connection cancelled"
        return 1
    fi
}

# Function to connect by hostname
connect_by_hostname() {
    local target_hostname=$1
    local devices=$(get_tailscale_devices)
    
    if [ -z "$devices" ]; then
        print_status $RED "❌ No devices available"
        return 1
    fi
    
    local found_ip=""
    local found_hostname=""
    
    while IFS='|' read -r ip hostname rest; do
        if [ "$hostname" = "$target_hostname" ] || [[ "$hostname" == *"$target_hostname"* ]]; then
            found_ip="$ip"
            found_hostname="$hostname"
            break
        fi
    done <<< "$devices"
    
    if [ -z "$found_ip" ]; then
        print_status $RED "❌ Device '$target_hostname' not found"
        echo ""
        print_status $YELLOW "Available devices:"
        list_devices
        return 1
    fi
    
    print_status $GREEN "🔗 Connecting to $found_hostname ($found_ip)..."
    
    # Try common usernames
    local usernames=("dan7554" "$USER" "pi" "ubuntu" "admin")
    
    for username in "${usernames[@]}"; do
        if timeout 5 ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$username@$found_ip" "echo 'Connection successful'" 2>/dev/null; then
            exec ssh "$username@$found_ip"
            return 0
        fi
    done
    
    # Fallback to interactive
    read -p "Enter username for $found_hostname: " custom_username
    if [ -n "$custom_username" ]; then
        exec ssh "$custom_username@$found_ip"
    else
        print_status $RED "❌ Connection cancelled"
        return 1
    fi
}

# Function to show Pi-specific quick connections
show_pi_shortcuts() {
    local devices=$(get_tailscale_devices)
    if [ -z "$devices" ]; then
        return 1
    fi
    
    echo ""
    print_status $BLUE "🎯 Quick Pi Connections:"
    
    echo "$devices" | while IFS='|' read -r ip hostname rest; do
        if [[ "$hostname" == *"rpicam"* ]] || [[ "$hostname" == *"pi"* ]] || [[ "$rest" == *"linux"* ]]; then
            echo "   $0 $hostname    # Connect to $hostname"
        fi
    done
}

# Function to show interactive menu
interactive_menu() {
    while true; do
        print_status $CYAN "🔵 Tailscale SSH Manager"
        print_status $CYAN "========================"
        echo ""
        
        if ! list_devices; then
            return 1
        fi
        
        show_pi_shortcuts
        
        echo ""
        print_status $YELLOW "Options:"
        echo "  [1-N] Connect to device by number"
        echo "  [q]   Quit"
        echo ""
        read -p "Select device (number or q): " choice
        
        case $choice in
            q|Q|quit|exit)
                print_status $YELLOW "👋 Goodbye!"
                exit 0
                ;;
            ''|*[!0-9]*)
                print_status $RED "❌ Please enter a valid number or 'q'"
                echo ""
                continue
                ;;
            *)
                connect_by_number "$choice"
                break
                ;;
        esac
    done
}

# Function to show usage
show_usage() {
    echo "🔵 Tailscale SSH Manager"
    echo "========================"
    echo ""
    echo "Usage: $0 [hostname|number]"
    echo ""
    echo "Examples:"
    echo "  $0                    # Interactive menu"
    echo "  $0 rpicam2           # Connect to rpicam2"
    echo "  $0 1                 # Connect to device #1"
    echo "  $0 --list            # List all devices"
    echo "  $0 --help            # Show this help"
    echo ""
    echo "Commands:"
    echo "  list, ls, --list     Show all Tailscale devices"
    echo "  help, --help, -h     Show this help message"
    echo ""
}

# Main script logic
main() {
    check_tailscale
    
    case "$1" in
        ""|"menu"|"interactive")
            interactive_menu
            ;;
        "list"|"ls"|"--list")
            list_devices
            ;;
        "help"|"--help"|"-h")
            show_usage
            ;;
        [0-9]*)
            # Numeric input - connect by number
            connect_by_number "$1"
            ;;
        *)
            # String input - connect by hostname
            connect_by_hostname "$1"
            ;;
    esac
}

# Run main function
main "$@"