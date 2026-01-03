#!/bin/bash
# Quick test to verify Fargate streaming pipeline

NLB_DNS="broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com"
REGION="us-east-1"

echo "═══════════════════════════════════════════════════════"
echo "Fargate Streaming Pipeline Test"
echo "═══════════════════════════════════════════════════════"

# Check service status
echo ""
echo "[1] Fargate Service Status"
aws ecs describe-services --cluster broadcast-cluster --services mediamtx-service \
  --region $REGION --query 'services[0].{Running:runningCount,Desired:desiredCount,Status:status}' --output text

# Check RPi stream
echo ""
echo "[2] RPi Stream Source"
ssh -i ~/.ssh/id_ed25519 -o ConnectTimeout=3 dan7554@100.80.96.23 \
  "pgrep -fa ffmpeg >/dev/null && echo '✅ RPi streaming active' || echo '❌ RPi not streaming'" 2>/dev/null || echo "⚠️  RPi check failed"

# Check logs for stream activity
echo ""
echo "[3] Recent MediaMTX Activity"
aws logs tail /ecs/mediamtx --region $REGION --since 3m 2>&1 | grep -E "listener opened|publisher|receiver|ERR" | tail -5

# Test NLB connectivity
echo ""
echo "[4] NLB Connectivity Test"
echo "Testing RTSP port (8554)..."
timeout 2 bash -c "exec 3<>/dev/tcp/$NLB_DNS/8554 && echo '✅ RTSP reachable' || echo '❌ RTSP unreachable'" 2>/dev/null || echo "❌ RTSP timeout"

echo ""
echo "Testing HLS port (8888)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://$NLB_DNS:8888/hls/rpicam2/index.m3u8" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
  echo "✅ HLS reachable (HTTP 200)"
elif [ "$HTTP_CODE" != "000" ]; then
  echo "⚠️  HLS returned HTTP $HTTP_CODE"
else
  echo "❌ HLS unreachable"
fi

echo ""
echo "Testing RTMP port (1935)..."
timeout 2 bash -c "exec 3<>/dev/tcp/$NLB_DNS/1935 && echo '✅ RTMP reachable' || echo '❌ RTMP unreachable'" 2>/dev/null || echo "❌ RTMP timeout"

# Target group health
echo ""
echo "[5] Target Group Health"
for TG in mediamtx-rtsp mediamtx-rtmp mediamtx-streaming; do
  TG_ARN=$(aws elbv2 describe-target-groups --names "$TG" --region $REGION --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
  if [ -z "$TG_ARN" ]; then continue; fi
  STATE=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --region $REGION --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text 2>/dev/null)
  echo "  $TG: $STATE"
done

echo ""
echo "═══════════════════════════════════════════════════════"
echo "Test complete. Check logs above for issues."
echo "═══════════════════════════════════════════════════════"
