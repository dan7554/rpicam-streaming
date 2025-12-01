#!/bin/bash

# Get Current Public IP of MediaMTX ECS Task
# Updates rpicam-stream.sh with the current public IP

set -e

REGION="${AWS_REGION:-us-east-2}"
PRIVATE_IP="172.31.8.36"  # Known private IP of the MediaMTX ECS task

echo "🔍 Checking current public IP of MediaMTX server..."

# Get current public IP
PUBLIC_IP=$(aws ec2 describe-network-interfaces \
    --filters "Name=private-ip-address,Values=$PRIVATE_IP" \
    --region "$REGION" \
    --query 'NetworkInterfaces[0].Association.PublicIp' \
    --output text 2>/dev/null)

if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "None" ]; then
    echo "❌ Could not find public IP for task"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Verify ECS task is running:"
    echo "     aws ecs describe-services --cluster mediamtx-cluster --services mediamtx-service --region us-east-2 | jq '.services[0].{Status: status, RunningCount: runningCount}'"
    echo ""
    echo "  2. Check if task has a public IP assigned:"
    echo "     aws ecs describe-services --cluster mediamtx-cluster --services mediamtx-service --region us-east-2 | jq '.services[0].networkConfiguration.awsvpcConfiguration.assignPublicIp'"
    exit 1
fi

echo "✓ Current public IP: $PUBLIC_IP"

# Test connectivity
echo ""
echo "🧪 Testing connectivity to port 8554..."
if python3 -c "import socket; s=socket.socket(); result=s.connect_ex(('$PUBLIC_IP', 8554)); s.close(); exit(0 if result == 0 else 1)" 2>/dev/null; then
    echo "✓ Port 8554 is reachable"
else
    echo "❌ Port 8554 is NOT reachable"
    echo "   Check security group rules and ECS task status"
    exit 1
fi

# Check if rpicam-stream.sh exists and update it
SCRIPT_PATH="/Users/dchristiani/code/media-mtx/rpi/rpicam-stream.sh"

if [ -f "$SCRIPT_PATH" ]; then
    echo ""
    echo "📝 Current RTSP_SERVER in rpicam-stream.sh:"
    grep "^RTSP_SERVER=" "$SCRIPT_PATH"
    
    # Update if different
    CURRENT_IP=$(grep "^RTSP_SERVER=" "$SCRIPT_PATH" | cut -d'"' -f2 | cut -d':' -f1)
    
    if [ "$CURRENT_IP" != "$PUBLIC_IP" ]; then
        echo ""
        echo "⚠️  IP has changed from $CURRENT_IP to $PUBLIC_IP"
        echo "🔄 Updating rpicam-stream.sh..."
        
        sed -i '' "s/RTSP_SERVER=\"[0-9.]*:8554\"/RTSP_SERVER=\"$PUBLIC_IP:8554\"/" "$SCRIPT_PATH"
        
        echo "✓ Updated successfully"
        echo ""
        echo "📝 New configuration:"
        grep "^RTSP_SERVER=" "$SCRIPT_PATH"
        
        echo ""
        echo "⚠️  IMPORTANT: Sync the updated file to your Raspberry Pi:"
        echo "   scp $SCRIPT_PATH pi@<rpi-ip>:/home/pi/"
        echo "   ssh pi@<rpi-ip>"
        echo "   sudo systemctl restart rpicam-stream.service"
    else
        echo ""
        echo "✓ Configuration is up to date"
    fi
else
    echo ""
    echo "⚠️  rpicam-stream.sh not found at $SCRIPT_PATH"
fi

echo ""
echo "=== Quick Reference ==="
echo "RTSP URL: rtsp://$PUBLIC_IP:8554/rpicam2"
echo ""
echo "To update the RPi script manually:"
echo "  sed -i \"s/RTSP_SERVER=.*/RTSP_SERVER=\\\"$PUBLIC_IP:8554\\\"/\" rpi/rpicam-stream.sh"
echo ""
