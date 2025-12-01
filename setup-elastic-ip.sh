#!/bin/bash

# Setup Elastic IP for RTSP Server
# Allocates a static Elastic IP and associates it with the ECS task
# Then updates DNS to point to this stable IP

set -e

REGION="${AWS_REGION:-us-east-2}"
PRIVATE_IP="172.31.8.36"  # Private IP of MediaMTX ECS task
ENI_ID="eni-0e235a4da62a47808"  # Network interface ID of the task
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

# Step 1: Check if Elastic IP already exists
log "Checking for existing Elastic IP..."

ALLOC_ID=$(aws ec2 describe-addresses \
    --filters "Name=network-interface-id,Values=$ENI_ID" \
    --region "$REGION" \
    --query 'Addresses[0].AllocationId' \
    --output text 2>/dev/null)

if [ "$ALLOC_ID" != "None" ] && [ -n "$ALLOC_ID" ]; then
    log "Elastic IP already allocated: $ALLOC_ID"
    EIP=$(aws ec2 describe-addresses \
        --allocation-ids "$ALLOC_ID" \
        --region "$REGION" \
        --query 'Addresses[0].PublicIp' \
        --output text)
else
    warn "No existing Elastic IP found, allocating new one..."
    
    RESULT=$(aws ec2 allocate-address \
        --domain vpc \
        --region "$REGION")
    
    ALLOC_ID=$(echo "$RESULT" | jq -r '.AllocationId')
    EIP=$(echo "$RESULT" | jq -r '.PublicIp')
    
    log "Elastic IP allocated: $EIP (Allocation ID: $ALLOC_ID)"
    
    # Associate the Elastic IP with the task's ENI
    log "Associating Elastic IP with task..."
    aws ec2 associate-address \
        --allocation-id "$ALLOC_ID" \
        --network-interface-id "$ENI_ID" \
        --private-ip-address "$PRIVATE_IP" \
        --region "$REGION" > /dev/null
    
    log "Elastic IP associated"
fi

# Step 2: Test connectivity
log "Testing connectivity to $EIP:8554..."
if python3 -c "import socket; s=socket.socket(); result=s.connect_ex(('$EIP', 8554)); s.close(); exit(0 if result == 0 else 1)" 2>/dev/null; then
    log "Port 8554 is reachable on Elastic IP"
else
    error "Port 8554 is NOT reachable on Elastic IP"
fi

# Step 3: Update DNS (if Zone ID provided)
if [ -n "$HOSTED_ZONE_ID" ] && [ "$HOSTED_ZONE_ID" != "none" ]; then
    log "Updating Route53 DNS record for $DOMAIN..."
    
    cat > /tmp/dns-change.json << EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$DOMAIN",
      "Type": "A",
      "TTL": 300,
      "ResourceRecords": [{"Value": "$EIP"}]
    }
  }]
}
EOF
    
    aws route53 change-resource-record-sets \
        --hosted-zone-id "$HOSTED_ZONE_ID" \
        --change-batch file:///tmp/dns-change.json \
        --region "$REGION"
    
    log "DNS record updated: $DOMAIN → $EIP"
    warn "DNS propagation may take 5-30 minutes"
    
    rm -f /tmp/dns-change.json
else
    warn "Route53 Zone ID not provided (use ROUTE53_ZONE_ID env var)"
    echo ""
    echo "To update DNS manually:"
    echo "  ROUTE53_ZONE_ID=<your-zone-id> $0"
    echo ""
fi

# Step 4: Update rpicam-stream.sh
echo ""
echo "=== Elastic IP Setup Complete ==="
echo ""
echo "Elastic IP: $EIP"
echo "RTSP URL: rtsp://$EIP:8554/rpicam2"
echo "Domain: $DOMAIN"
echo ""

SCRIPT_PATH="/Users/dchristiani/code/media-mtx/rpi/rpicam-stream.sh"
if [ -f "$SCRIPT_PATH" ]; then
    log "Updating rpicam-stream.sh..."
    
    # Update to use Elastic IP
    sed -i '' "s/RTSP_SERVER=\"[^\"]*:8554\"/RTSP_SERVER=\"$EIP:8554\"/" "$SCRIPT_PATH"
    
    echo ""
    echo "Updated configuration:"
    grep "^RTSP_SERVER=" "$SCRIPT_PATH"
fi

echo ""
echo "Next steps:"
echo "  1. Sync updated script to RPi:"
echo "     scp rpi/rpicam-stream.sh pi@<rpi-ip>:/home/pi/"
echo ""
echo "  2. Restart the stream service:"
echo "     ssh pi@<rpi-ip>"
echo "     sudo systemctl restart rpicam-stream.service"
echo ""
echo "  3. (Optional) Setup DNS with Route53:"
echo "     ROUTE53_ZONE_ID=<zone-id> $0"
echo ""
echo "This Elastic IP will remain stable even if the ECS task is restarted!"
echo ""
