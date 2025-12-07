#!/bin/bash

# Quick Update Script - Update RPi when MediaMTX ECS Task IP Changes
# Run this after redeploying MediaMTX to update rpicam2 streaming configuration

set -e

AWS_REGION="us-east-2"
CLUSTER="mediamtx-cluster"
PI_USER="dan7554"
PI_HOST="192.168.50.96"

echo "🔍 Finding MediaMTX ECS task public IP..."

# Get the MediaMTX task's public IP
NEW_IP=$(aws ecs describe-tasks \
  --cluster $CLUSTER \
  --tasks $(aws ecs list-tasks --cluster $CLUSTER --region $AWS_REGION --query 'taskArns[0]' --output text) \
  --region $AWS_REGION \
  --query 'tasks[0].attachments[?type==`ElasticNetworkInterface`].details[?name==`primaryPublicIpv4Address`].value' \
  --output text)

if [ -z "$NEW_IP" ] || [ "$NEW_IP" = "None" ]; then
  echo "❌ Could not find MediaMTX public IP. Is the ECS task running?"
  exit 1
fi

echo "✅ MediaMTX Public IP: $NEW_IP"
echo ""
echo "📝 Updating rpicam2 configuration..."

# SSH to Pi and update the script
ssh $PI_USER@$PI_HOST << EOF
  echo "🔧 Updating rpicam-stream.sh..."
  sed -i "s/RTSP_SERVER_DOMAIN=\"[^\"]*\"/RTSP_SERVER_DOMAIN=\"$NEW_IP\"/g" /home/dan7554/rpicam-stream.sh
  
  echo "🔄 Restarting rpicam-stream service..."
  sudo systemctl restart rpicam-stream.service
  
  echo "📊 Checking service status..."
  sleep 3
  sudo systemctl status rpicam-stream.service --no-pager | head -15
  
  echo "📋 Recent logs..."
  sudo journalctl -u rpicam-stream.service -n 5 --no-pager
EOF

echo ""
echo "✅ Update complete!"
echo "✅ rpicam2 should now be streaming to $NEW_IP:1935"
echo ""
echo "🧪 Verify streaming with:"
echo "   aws logs tail /ecs/mediamtx --follow=false | grep rpicam2"
