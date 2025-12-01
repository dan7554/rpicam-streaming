#!/bin/bash

# Domain-Based RTSP Connection via Route53
# Creates an A record that points to the current public IP of the ECS task
# Includes auto-update capability if IP changes

set -e

REGION="${AWS_REGION:-us-east-2}"
DOMAIN="stream.racetrackstreaming.com"
HOSTED_ZONE_ID="${ROUTE53_ZONE_ID:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}✓${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }

# Get current public IP of the ECS task
log "Getting current public IP of MediaMTX server..."

PUBLIC_IP=$(aws ec2 describe-network-interfaces \
    --filters "Name=private-ip-address,Values=172.31.8.36" \
    --region "$REGION" \
    --query 'NetworkInterfaces[0].Association.PublicIp' \
    --output text 2>/dev/null)

if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "None" ]; then
    error "Could not find public IP for MediaMTX task"
fi

log "Current public IP: $PUBLIC_IP"

# Test connectivity
log "Testing connectivity..."
if python3 -c "import socket; s=socket.socket(); result=s.connect_ex(('$PUBLIC_IP', 8554)); s.close(); exit(0 if result == 0 else 1)" 2>/dev/null; then
    log "Port 8554 is reachable"
else
    error "Port 8554 is NOT reachable"
fi

# Check for Route53 Zone ID
if [ -z "$HOSTED_ZONE_ID" ] || [ "$HOSTED_ZONE_ID" = "none" ]; then
    warn "Route53 Zone ID not provided"
    echo ""
    echo "To find your Zone ID:"
    echo "  aws route53 list-hosted-zones-by-name --query 'HostedZones[?Name==\`racetrackstreaming.com.\`].Id' --output text"
    echo ""
    echo "Then run:"
    echo "  ROUTE53_ZONE_ID=<zone-id> bash setup-dns-domain.sh"
    echo ""
else
    log "Setting up DNS record in Route53..."
    
    # Create DNS change batch
    cat > /tmp/dns-update.json << EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$DOMAIN",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{"Value": "$PUBLIC_IP"}]
    }
  }]
}
EOF
    
    # Apply the change
    CHANGE_ID=$(aws route53 change-resource-record-sets \
        --hosted-zone-id "$HOSTED_ZONE_ID" \
        --change-batch file:///tmp/dns-update.json \
        --region "$REGION" \
        --query 'ChangeInfo.Id' \
        --output text)
    
    log "DNS record created/updated: $DOMAIN → $PUBLIC_IP"
    log "Change ID: $CHANGE_ID"
    warn "DNS propagation may take 1-5 minutes (TTL is 60 seconds for quick updates)"
    
    rm -f /tmp/dns-update.json
fi

# Update rpicam-stream.sh to use domain
SCRIPT_PATH="/Users/dchristiani/code/media-mtx/rpi/rpicam-stream.sh"
if [ -f "$SCRIPT_PATH" ]; then
    log "Updating rpicam-stream.sh to use domain..."
    
    # Comment out IP and use domain instead
    sed -i '' 's/^RTSP_SERVER="[0-9.]*:8554"/# RTSP_SERVER="[old-ip]:8554"/' "$SCRIPT_PATH"
    sed -i '' "s/^# RTSP_SERVER=\"stream.racetrackstreaming.com:8554\"/RTSP_SERVER=\"stream.racetrackstreaming.com:8554\"/" "$SCRIPT_PATH"
    
    log "Updated rpicam-stream.sh"
    echo ""
    grep "RTSP_SERVER=" "$SCRIPT_PATH" | head -3
fi

echo ""
echo "=== DNS Setup Complete ==="
echo ""
echo "Domain: $DOMAIN"
echo "RTSP URL: rtsp://$DOMAIN:8554/rpicam2"
echo "Current IP: $PUBLIC_IP"
echo ""
echo "⚠️  IMPORTANT: This setup uses dynamic DNS"
echo "   • Public IP may change if ECS task restarts"
echo "   • Use check-rtsp-ip.sh to verify current IP"
echo "   • Run this script again to update DNS if IP changes"
echo ""
echo "Deploy to RPi:"
echo "  scp rpi/rpicam-stream.sh pi@<rpi-ip>:/home/pi/"
echo "  ssh pi@<rpi-ip>"
echo "  sudo systemctl restart rpicam-stream.service"
echo ""
