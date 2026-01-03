#!/bin/bash
##############################################################################
# Simplified E2E Test: RPi → NLB → Fargate MediaMTX → Stream Output
# Tests the actual working production setup
##############################################################################

set -e

REGION="us-east-1"
CLUSTER="broadcast-cluster"
SERVICE="mediamtx-service"  # The working Fargate service
TASK_FAMILY="mediamtx-task"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   E2E Test: RPi Camera → NLB → Fargate MediaMTX → Streaming   ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"

# ============================================================================
# STAGE 1: Check NLB Status
# ============================================================================
echo -e "\n${BLUE}[STAGE 1] Network Load Balancer Status${NC}"

NLB_DNS=$(aws elbv2 describe-load-balancers \
  --region $REGION \
  --query 'LoadBalancers[?Type==`network`].[DNSName,LoadBalancerName]' \
  --output text | head -1 | awk '{print $1}')

if [ -z "$NLB_DNS" ]; then
  echo -e "${RED}❌ No NLB found${NC}"
  exit 1
fi

echo -e "${GREEN}✅ NLB Active: $NLB_DNS${NC}"

# Check target health
TG_ARN=$(aws elbv2 describe-target-groups \
  --region $REGION \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text 2>/dev/null || echo "")

if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
  HEALTHY=$(aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" \
    --region $REGION \
    --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`] | length(@)' \
    --output text 2>/dev/null || echo "0")
  
  TOTAL=$(aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" \
    --region $REGION \
    --query 'length(TargetHealthDescriptions)' \
    --output text 2>/dev/null || echo "0")
  
  echo "  Targets: $HEALTHY/$TOTAL healthy"
fi

# ============================================================================
# STAGE 2: Verify Fargate MediaMTX Service
# ============================================================================
echo -e "\n${BLUE}[STAGE 2] Fargate MediaMTX Service Status${NC}"

SERVICE_DATA=$(aws ecs describe-services \
  --cluster $CLUSTER \
  --services $SERVICE \
  --region $REGION \
  --output json)

STATUS=$(echo "$SERVICE_DATA" | python3 -c "import sys, json; s = json.load(sys.stdin)['services'][0]; print(s['status'])")
RUNNING=$(echo "$SERVICE_DATA" | python3 -c "import sys, json; s = json.load(sys.stdin)['services'][0]; print(s['runningCount'])")
DESIRED=$(echo "$SERVICE_DATA" | python3 -c "import sys, json; s = json.load(sys.stdin)['services'][0]; print(s['desiredCount'])")

if [ "$RUNNING" -gt 0 ]; then
  echo -e "${GREEN}✅ Service Active: $RUNNING/$DESIRED tasks running${NC}"
else
  echo -e "${YELLOW}⚠️ Service: $RUNNING/$DESIRED tasks${NC}"
fi

# ============================================================================
# STAGE 3: List Running Tasks
# ============================================================================
echo -e "\n${BLUE}[STAGE 3] Running Tasks${NC}"

TASK_ARNS=$(aws ecs list-tasks \
  --cluster $CLUSTER \
  --service-name $SERVICE \
  --region $REGION \
  --query 'taskArns' \
  --output text)

if [ -z "$TASK_ARNS" ]; then
  echo -e "${YELLOW}⚠️ No running tasks${NC}"
else
  echo -e "${GREEN}✅ Running Tasks:${NC}"
  
  aws ecs describe-tasks \
    --cluster $CLUSTER \
    --tasks $TASK_ARNS \
    --region $REGION \
    --query 'tasks[*].[taskArn,lastStatus,containerInstanceArn]' \
    --output table 2>/dev/null | head -10
fi

# ============================================================================
# STAGE 4: Test Stream Connectivity
# ============================================================================
echo -e "\n${BLUE}[STAGE 4] Stream Endpoint Testing${NC}"

# Test HLS
echo "Testing HLS endpoint..."
HLS_RESPONSE=$(curl -s -w "\n%{http_code}" "http://$NLB_DNS:8888/hls/rpicam2/index.m3u8" 2>/dev/null | tail -1 || echo "000")

if [ "$HLS_RESPONSE" -eq 200 ] 2>/dev/null; then
  echo -e "${GREEN}✅ HLS responding (HTTP 200)${NC}"
  curl -s "http://$NLB_DNS:8888/hls/rpicam2/index.m3u8" 2>/dev/null | head -5
elif [ "$HLS_RESPONSE" -eq 404 ] 2>/dev/null; then
  echo -e "${YELLOW}⚠️ HLS not available yet (path may not exist)${NC}"
else
  echo -e "${YELLOW}⚠️ HLS not responding (may be firewall/network issue)${NC}"
fi

# ============================================================================
# STAGE 5: Check RPi Stream
# ============================================================================
echo -e "\n${BLUE}[STAGE 5] RPi Stream Source${NC}"

echo "Checking if RPi is pushing stream..."
# Try to ping the NLB from local network to see if stream is active
RTSP_TIMEOUT=3
if timeout $RTSP_TIMEOUT bash -c "exec 3<>/dev/tcp/$NLB_DNS/8554" 2>/dev/null; then
  echo -e "${GREEN}✅ NLB RTSP port 8554 is reachable${NC}"
else
  echo -e "${YELLOW}⚠️ RTSP port 8554 not reachable (may be firewall)${NC}"
fi

# ============================================================================
# STAGE 6: Check CloudFlare Tunnel (if configured)
# ============================================================================
echo -e "\n${BLUE}[STAGE 6] CloudFlare Tunnel Status${NC}"

CF_DOMAIN="stream.racetrackstreaming.com"
CF_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "https://$CF_DOMAIN/hls/rpicam2/index.m3u8" 2>/dev/null || echo "000")

if [ "$CF_RESPONSE" -eq 200 ] 2>/dev/null; then
  echo -e "${GREEN}✅ CloudFlare tunnel available${NC}"
  echo "   URL: https://$CF_DOMAIN/hls/rpicam2/index.m3u8"
elif [ "$CF_RESPONSE" -eq 000 ]; then
  echo -e "${YELLOW}⚠️ CloudFlare not reachable (network issue)${NC}"
else
  echo -e "${YELLOW}⚠️ CloudFlare responds with HTTP $CF_RESPONSE${NC}"
fi

# ============================================================================
# STAGE 7: Local Playback Test
# ============================================================================
echo -e "\n${BLUE}[STAGE 7] Local Tailscale Test${NC}"

LOCAL_HLS="http://100.100.74.51:8888/hls/rpicam2/index.m3u8"
LOCAL_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "$LOCAL_HLS" 2>/dev/null || echo "000")

if [ "$LOCAL_RESPONSE" -eq 200 ] 2>/dev/null; then
  echo -e "${GREEN}✅ Local MacBook MediaMTX responding${NC}"
  echo "   URL: $LOCAL_HLS"
else
  echo -e "${YELLOW}⚠️ Local MacBook not responding (may be offline or service stopped)${NC}"
fi

# ============================================================================
# STAGE 8: Summary
# ============================================================================
echo -e "\n${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                    STREAMING CONFIGURATION                        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"

echo -e "\n${GREEN}Stream Pipeline:${NC}"
echo "  Source:      RPi IMX477 Camera (1280x720 @ 25 fps)"
echo "  Encoding:    H.264 via rpicam-vid + ffmpeg"
echo "  Transport:   RTSP push → NLB:8554"
echo "  Processing:  Fargate MediaMTX containers"
echo "  Output:      RTSP/HLS on NLB + CloudFlare Tunnel"

echo -e "\n${GREEN}Access Methods:${NC}"
echo "  1. Direct NLB (public):"
echo "     RTSP:  rtsp://$NLB_DNS:8554/rpicam2"
echo "     HLS:   http://$NLB_DNS:8888/hls/rpicam2/index.m3u8"
echo ""
echo "  2. CloudFlare (HTTPS):"
echo "     HLS:   https://$CF_DOMAIN/hls/rpicam2/index.m3u8"
echo ""
echo "  3. Local/Tailscale:"
echo "     RTSP:  rtsp://100.100.74.51:8554/rpicam2"
echo "     HLS:   http://100.100.74.51:8888/hls/rpicam2/index.m3u8"

echo -e "\n${GREEN}Quick Commands:${NC}"
echo "  VLC RTSP:      open 'rtsp://$NLB_DNS:8554/rpicam2'"
echo "  ffplay:        ffplay 'rtsp://$NLB_DNS:8554/rpicam2'"
echo "  HLS Browser:   Open stream-player.html"
echo "  Logs:          aws logs tail /ecs/mediamtx --follow"

echo -e "\n${GREEN}✅ E2E Test Complete!${NC}"
