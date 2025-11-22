#!/bin/bash
# Quick Carrier Switcher for SIM8262A-M2
# Allows easy switching between configured carrier connections

echo "📱 SIM8262A-M2 Carrier Connection Manager"
echo "========================================="

# Check if running as root for connection changes
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root for connection management (use sudo)"
   exit 1
fi

# Function to list available connections
list_connections() {
    echo "📋 Available cellular connections:"
    nmcli connection show | grep gsm | nl -w2 -s') '
}

# Function to show active connections
show_active() {
    echo "📶 Currently active connections:"
    ACTIVE=$(nmcli connection show --active | grep gsm)
    if [ -z "$ACTIVE" ]; then
        echo "   None"
    else
        echo "$ACTIVE"
    fi
}

# Function to switch carrier
switch_carrier() {
    echo ""
    list_connections
    echo ""
    
    # Get available connections
    CONNECTIONS=($(nmcli connection show | grep gsm | awk '{print $1}'))
    
    if [ ${#CONNECTIONS[@]} -eq 0 ]; then
        echo "❌ No cellular connections found. Run setup-cellular-connection.sh first."
        return 1
    fi
    
    echo "Enter choice (number) or connection name:"
    read -p "Selection: " choice
    
    # Check if choice is a number
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        # Convert to array index (subtract 1)
        index=$((choice - 1))
        if [ $index -ge 0 ] && [ $index -lt ${#CONNECTIONS[@]} ]; then
            CONNECTION="${CONNECTIONS[$index]}"
        else
            echo "❌ Invalid choice number"
            return 1
        fi
    else
        # Use as connection name
        CONNECTION="$choice"
    fi
    
    # Disconnect all active cellular connections first
    echo "🔌 Disconnecting active cellular connections..."
    nmcli connection show --active | grep gsm | awk '{print $1}' | while read conn; do
        nmcli connection down "$conn" 2>/dev/null || true
    done
    
    # Connect to selected connection
    echo "🌐 Connecting to: $CONNECTION"
    if nmcli connection up "$CONNECTION"; then
        echo "✅ Successfully connected to $CONNECTION"
        
        # Show connection details
        echo ""
        echo "📊 Connection Status:"
        sleep 3  # Wait for connection to stabilize
        nmcli connection show "$CONNECTION" | grep -E "(gsm.apn|connection.id)"
        
        echo ""
        echo "📱 Device Status:"
        nmcli device status | grep -E "(gsm|wwan)"
        
    else
        echo "❌ Failed to connect to $CONNECTION"
        return 1
    fi
}

# Main menu
while true; do
    echo ""
    echo "🔧 Select action:"
    echo "1) List available connections"
    echo "2) Show active connections"  
    echo "3) Switch carrier connection"
    echo "4) Create new carrier connection"
    echo "5) Check modem status"
    echo "6) Exit"
    echo ""
    read -p "Choice [1-6]: " action
    
    case $action in
        1)
            echo ""
            list_connections
            ;;
        2)
            echo ""
            show_active
            ;;
        3)
            switch_carrier
            ;;
        4)
            echo ""
            echo "🚀 Launching carrier setup script..."
            if [ -f "./setup-cellular-connection.sh" ]; then
                ./setup-cellular-connection.sh
            else
                echo "❌ setup-cellular-connection.sh not found in current directory"
                echo "Make sure you're running this from the rpi directory"
            fi
            ;;
        5)
            echo ""
            echo "📡 Checking modem status..."
            if [ -f "./modem-manager.sh" ]; then
                ./modem-manager.sh check
            else
                echo "❌ modem-manager.sh not found in current directory"
                echo "Make sure you're running this from the rpi directory"
            fi
            ;;
        6)
            echo "👋 Goodbye!"
            exit 0
            ;;
        *)
            echo "❌ Invalid choice"
            ;;
    esac
done