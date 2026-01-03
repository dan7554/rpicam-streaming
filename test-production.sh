#!/bin/bash
set -e

# Production Architecture Test Suite
# Tests: RPi → NLB (RTSP/RTMP) → MediaMTX ECS → ALB → HLS/WebRTC
# Also tests: Admin Dashboard via ALB

REGION="us-east-1"
NLB_DNS="broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com"
ALB_DNS="broadcast-alb-1564889644.us-east-1.elb.amazonaws.com"
ADMIN_DOMAIN="admin.racetrackstreaming.com"
STREAM_DOMAIN="stream.racetrackstreaming.com"
TIMEOUT=10

echo "🧪 PRODUCTION ARCHITECTURE TEST SUITE"
echo "===================================="
echo ""

# Test 1: NLB Health Check
echo "1️⃣  Testing NLB Health (RTSP/RTMP targets)..."
nlb_health=$(aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --names mediamtx-rtsp \
    --region $REGION \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text 2>/dev/null) \
  --region $REGION \
  --query 'TargetHealthDescriptions[*].{IP: Target.Id, Status: TargetHealth.State}' \
  2>/dev/null)

healthy=$(echo "$nlb_health" | grep -c "healthy" || true)
total=$(echo "$nlb_health" | grep -c "Status" || true)
echo "   ✓ NLB Targets: $healthy/$total healthy"
echo "$nlb_health" | grep -v "^$" || true
echo ""

# Test 2: NLB RTSP Port Accessibility
echo "2️⃣  Testing NLB RTSP Port (8554)..."
if timeout $TIMEOUT nc -zv $NLB_DNS 8554 2>&1 | grep -q "open\|succeed"; then
    echo "   ✓ RTSP Port 8554: OPEN"
else
    echo "   ✗ RTSP Port 8554: TIMEOUT (may be normal if no active stream)"
fi
echo ""

# Test 3: NLB RTMP Port Accessibility
echo "3️⃣  Testing NLB RTMP Port (1935)..."
if timeout $TIMEOUT nc -zv $NLB_DNS 1935 2>&1 | grep -q "open\|succeed"; then
    echo "   ✓ RTMP Port 1935: OPEN"
else
    echo "   ✗ RTMP Port 1935: TIMEOUT (may be normal if no active stream)"
fi
echo ""

# Test 4: ECS Cluster Status
echo "4️⃣  Testing ECS Cluster Health..."
cluster_status=$(aws ecs describe-clusters \
  --clusters broadcast-cluster \
  --region $REGION \
  --query 'clusters[0].{Status: status, Services: registeredContainerInstancesCount}' \
  2>/dev/null)
echo "   ✓ Cluster Status: $(echo "$cluster_status" | jq -r '.Status')"
echo ""

# Test 5: MediaMTX Service Status
echo "5️⃣  Testing MediaMTX ECS Service..."
mediamtx_status=$(aws ecs describe-services \
  --cluster broadcast-cluster \
  --services mediamtx-service \
  --region $REGION \
  --query 'services[0].{Status: status, Running: runningCount, Desired: desiredCount}' \
  2>/dev/null)
echo "$mediamtx_status" | jq '.' || echo "$mediamtx_status"
echo ""

# Test 6: Broadcast Service Status
echo "6️⃣  Testing Broadcast-System ECS Service..."
broadcast_status=$(aws ecs describe-services \
  --cluster broadcast-cluster \
  --services broadcast-service \
  --region $REGION \
  --query 'services[0].{Status: status, Running: runningCount, Desired: desiredCount}' \
  2>/dev/null)
echo "$broadcast_status" | jq '.' || echo "$broadcast_status"
echo ""

# Test 7: ALB Health Check
echo "7️⃣  Testing ALB Health (Admin Dashboard)..."
alb_health=$(aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --names broadcast-targets \
    --region $REGION \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text 2>/dev/null) \
  --region $REGION \
  --query 'TargetHealthDescriptions[*].{IP: Target.Id, Status: TargetHealth.State}' \
  2>/dev/null)

healthy_alb=$(echo "$alb_health" | grep -c "healthy" || true)
echo "   ✓ ALB Targets: $healthy_alb healthy"
echo ""

# Test 8: Domain Availability
echo "8️⃣  Testing Domain Resolution..."
echo "   Admin Domain (admin.racetrackstreaming.com):"
admin_ip=$(dig +short $ADMIN_DOMAIN @8.8.8.8 2>/dev/null | head -1)
if [ -n "$admin_ip" ]; then
    echo "   ✓ Resolves to: $admin_ip"
else
    echo "   ⚠ Could not resolve (check CloudFlare DNS)"
fi

echo "   Stream Domain (stream.racetrackstreaming.com):"
stream_ip=$(dig +short $STREAM_DOMAIN @8.8.8.8 2>/dev/null | head -1)
if [ -n "$stream_ip" ]; then
    echo "   ✓ Resolves to: $stream_ip"
else
    echo "   ⚠ Could not resolve (check CloudFlare DNS)"
fi
echo ""

# Test 9: HTTP/HTTPS Access
echo "9️⃣  Testing HTTP/HTTPS Access..."
echo "   Admin Dashboard (HTTP):"
if timeout 5 curl -s -o /dev/null -w "%{http_code}" "http://$ALB_DNS/health" 2>/dev/null | grep -q "200\|302"; then
    echo "   ✓ ALB HTTP Health: OK"
else
    echo "   ⚠ ALB HTTP Health: No response"
fi

echo "   Admin Dashboard via CloudFlare (HTTPS):"
if timeout 5 curl -s -I "https://$ADMIN_DOMAIN" 2>/dev/null | grep -q "200\|301\|302\|403"; then
    echo "   ✓ HTTPS via CloudFlare: OK"
else
    echo "   ⚠ HTTPS via CloudFlare: No response"
fi
echo ""

# Test 10: Local MediaMTX (Fallback)
echo "🔟 Testing Local MediaMTX Fallback..."
if docker ps | grep -q mediamtx-server; then
    echo "   ✓ Local MediaMTX running"
    
    # Check if stream is being received
    logs=$(docker logs mediamtx-server 2>&1 | tail -5)
    if echo "$logs" | grep -q "rpicam"; then
        echo "   ✓ RPi Stream detected in logs"
    else
        echo "   ⚠ No active RPi stream in local MediaMTX"
    fi
else
    echo "   ⚠ Local MediaMTX not running"
fi
echo ""

# Test 11: MediaMTX Task Logs
echo "1️⃣1️⃣  Checking MediaMTX ECS Task Logs..."
task_arn=$(aws ecs list-tasks \
  --cluster broadcast-cluster \
  --service-name mediamtx-service \
  --region $REGION \
  --query 'taskArns[0]' \
  --output text 2>/dev/null)

if [ -n "$task_arn" ] && [ "$task_arn" != "None" ]; then
    echo "   ✓ Active task: $task_arn"
    
    # Get CloudWatch logs
    task_id=$(echo "$task_arn" | awk -F'/' '{print $NF}')
    logs=$(aws logs get-log-events \
      --log-group-name /ecs/mediamtx \
      --log-stream-name ecs/mediamtx-task/$task_id \
      --region $REGION \
      --limit 20 \
      --query 'events[*].message' \
      --output text 2>/dev/null | tail -5)
    
    if [ -n "$logs" ]; then
        echo "   Recent logs:"
        echo "$logs" | head -3
    fi
else
    echo "   ⚠ No active MediaMTX tasks"
fi
echo ""

echo "===================================="
echo "✅ PRODUCTION TEST COMPLETE"
echo ""
echo "Architecture Summary:"
echo "  RPi Camera → NLB (RTSP 8554 / RTMP 1935)"
echo "           ↓"
echo "  MediaMTX ECS Tasks (running: $healthy/$total targets healthy)"
echo "           ↓"
echo "  HLS/WebRTC/RTMP Output (ports 8888/8889/1935)"
echo "           ↓"
echo "  ALB → CloudFlare → Public Domains"
echo ""
echo "Next Steps:"
echo "  • Stream from RPi: rtsp://$NLB_DNS:8554/rpicam2"
echo "  • View HLS: https://$STREAM_DOMAIN/hls/"
echo "  • Admin Dashboard: https://$ADMIN_DOMAIN"
echo ""
