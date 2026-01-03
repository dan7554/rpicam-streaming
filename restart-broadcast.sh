#!/bin/bash
echo "🔄 Restarting broadcast service with new config..."

aws ecs update-service \
  --cluster broadcast-cluster \
  --service broadcast-service \
  --force-new-deployment \
  --region us-east-1 > /dev/null

echo "✅ Restart initiated"
echo "⏳ Waiting 30 seconds for new task to start..."
sleep 30

echo ""
aws logs tail /ecs/broadcast --since=1m --region us-east-1 2>&1 | grep -i "health\|camera\|online" | tail -5
