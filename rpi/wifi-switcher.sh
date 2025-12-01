#!/bin/bash

# WiFi Network Switcher for Raspberry Pi
# Easily switch between Starlink and regular WiFi networks

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Network configurations
STARLINK_SSID="rpicam2-starlink"
STARLINK_PASS="dan1007554"
REGULAR_SSID="bestskiieronthemountain_5G"
REGULAR_PASS="dananddessa"  # Set this if needed

# Function to display usage
usage() {
    echo -e "${BLUE}WiFi Switcher for Raspberry Pi${NC}"
    echo ""
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  starlink     Switch to Starlink WiFi (rpicam2-starlink)"
    echo "  regular      Switch to regular WiFi (rpicam2)"
    echo "  status       Show current WiFi connection"
    echo "  list         List available WiFi networks"
    echo "  help         Show this help message"
    echo ""
}

# Function to show current WiFi
show_status() {
    echo -e "${BLUE}📡 Current WiFi Connection:${NC}"
    nmcli connection show --active | grep "connection.id" | head -1 | awk '{print $NF}'
    echo ""
    echo -e "${BLUE}📍 Current IP Address:${NC}"
    hostname -I
    echo ""
}

# Function to list available networks
list_networks() {
    echo -e "${BLUE}📶 Available WiFi Networks:${NC}"
    nmcli device wifi list --rescan auto
    echo ""
}

# Function to connect to Starlink
connect_starlink() {
    echo -e "${YELLOW}🌟 Connecting to $STARLINK_SSID...${NC}"
    
    # First, disconnect from any active connection
    sudo nmcli connection down id "$REGULAR_SSID" 2>/dev/null || true
    
    # Check if connection profile exists, if not create it
    if ! nmcli connection show "$STARLINK_SSID" &>/dev/null; then
        echo -e "${YELLOW}📝 Creating connection profile for $STARLINK_SSID...${NC}"
        sudo nmcli connection add type wifi con-name "$STARLINK_SSID" ifname wlan0 ssid "$STARLINK_SSID" -- wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$STARLINK_PASS"
    fi
    
    # Connect using the profile
    if sudo nmcli connection up "$STARLINK_SSID"; then
        echo -e "${GREEN}✅ Successfully connected to $STARLINK_SSID${NC}"
        sleep 2
        echo -e "${BLUE}📍 New IP Address:${NC}"
        hostname -I
    else
        echo -e "${RED}❌ Failed to connect to $STARLINK_SSID${NC}"
        exit 1
    fi
}

# Function to connect to regular WiFi
connect_regular() {
    echo -e "${YELLOW}🌐 Connecting to $REGULAR_SSID...${NC}"
    
    # First, disconnect from Starlink
    sudo nmcli connection down id "$STARLINK_SSID" 2>/dev/null || true
    
    # Check if connection profile exists, if not create it
    if ! nmcli connection show "$REGULAR_SSID" &>/dev/null; then
        echo -e "${YELLOW}📝 Creating connection profile for $REGULAR_SSID...${NC}"
        if [ -z "$REGULAR_PASS" ]; then
            sudo nmcli connection add type wifi con-name "$REGULAR_SSID" ifname wlan0 ssid "$REGULAR_SSID" -- wifi-sec.key-mgmt none
        else
            sudo nmcli connection add type wifi con-name "$REGULAR_SSID" ifname wlan0 ssid "$REGULAR_SSID" -- wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$REGULAR_PASS"
        fi
    fi
    
    # Connect using the profile
    if sudo nmcli connection up "$REGULAR_SSID"; then
        echo -e "${GREEN}✅ Successfully connected to $REGULAR_SSID${NC}"
        sleep 2
        echo -e "${BLUE}📍 New IP Address:${NC}"
        hostname -I
    else
        echo -e "${RED}❌ Failed to connect to $REGULAR_SSID${NC}"
        exit 1
    fi
}

# Parse command line arguments
case "${1:-help}" in
    starlink)
        connect_starlink
        ;;
    regular)
        connect_regular
        ;;
    status)
        show_status
        ;;
    list)
        list_networks
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo -e "${RED}Unknown option: $1${NC}"
        echo ""
        usage
        exit 1
        ;;
esac
