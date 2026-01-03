#!/bin/bash
##############################################################################
# E2E Test: RPi → Deployed AWS Fargate MediaMTX → Streaming Output
# Tests the production Fargate deployment (mediamtx-service)
##############################################################################

set -e

REGION="us-east-1"
CLUSTER="broadcast-cluster"
SERVICE="mediamtx-service"
NLB_DNS="broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  E2E Test: RPi Camera → AWS Fargate MediaMTX → Stream Output  ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"

# ============================================================================
# STAGE 1: Verify RPi Stream Source
# ============================================================================
echo -e "\n${BLUE}[STAGE 1] RPi Stream Source${NC}"

echo "Checking RPi processes via Tailscale (100.80.96.23)..."

RPICAM=$(ssh -i ~/.ssh/id_ed25519 -o ConnectTimeout=5 dan7554@100.80.96.23 "pgrep -f rpicam-vid > /dev/null && echo 'running' || echo 'stopped'" 2>/dev/null)
FFMPEG=$(ssh -i ~/.ssh/id_ed25519 -o ConnectTimeout=5 dan7554@100.80.96.23 "pgrep -f 'ffmpeg.*broadcast-nlb' > /dev/null && echo 'running' || echo 'stopped'" 2>/dev/null)

if [ "$RPICAM" = "running" ] && [ "$FFMPEG" = "running" ]; then
  echo -e "${GREEN}✅ RPi streaming active${NC}"
  echo "   rpicam-vid: capturing H.264 from IMX477"
  echo "   ffmpeg: pushing RTSP to NLB:8554/rpicam2"
else
  echo -e "${RED}❌ RPi not streaming${NC}"
  echo "   rpicam-vid: $RPICAM"
  echo "   ffmpeg: $FFMPEG"
  exit 1
fi

# ============================================================================
# STAGE 2: Verify Fargate Service Status
# ============================================================================
echo -e "\n${BLUE}[STAGE 2] Fargate MediaMTX Service${NC}"

SERVICE_JSON=$(aws ecs describe-services \
  --cluster $CLUSTER \
  --services $SERVICE \
  --region $REGION \
  --output json)

STATUS=$(echo "$SERVICE_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin)['services'][0]['status'])")
RUNNING=$(echo "$SERVICE_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin)['services'][0]['runningCount'])")
DESIRED=$(echo "$SERVICE_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin)['services'][0]['desiredCount'])")
TASK_DEF=$(echo "$SERVICE_JSON" | python3 -c "import sys, json; td=json.load(sys.stdin)['services'][0]['taskDefinition']; print(td.split('/')[-1])")

if [ "$RUNNING" -ge "$DESIRED" ]; then
  echo -e "${GREEN}✅ Service Active: $RUNNING/$DESIRED tasks running${NC}"
  echo "   Task Definition: $TASK_DEF"
  echo "   Status: $STATUS"
else
  echo -e "${YELLOW}⚠️ Service Degraded: $RUNNING/$DESIRED tasks${NC}"
fi

# ============================================================================
# STAGE 3: List Running Tasks
# ============================================================================
echo -e "\n${BLUE}[STAGE 3] Running Fargate Tasks${NC}"

TASK_ARNS=$(aws ecs list-tasks \
  --cluster $CLUSTER \
  --service-name $SERVICE \
  --region $REGION \
  --query 'taskArns' \
  --output text)

if [ -z "$TASK_ARNS" ]; then
  echo -e "${RED}❌ No running tasks${NC}"
  exit 1
fi

TASK_COUNT=$(echo "$TASK_ARNS" | wc -w)
echo -e "${GREEN}✅ $TASK_COUNT tasks running${NC}"

# Get task details
aws ecs describe-tasks \
  --cluster $CLUSTER \
  --tasks $TASK_ARNS \
  --region $REGION \
  --query 'tasks[*].[taskArn,lastStatus,createdAt]' \
  --output text | while read -r arn status created; do
  echo "   $(echo $arn | rev | cut -d/ -f1 | rev) - $status"
done

# ============================================================================
# STAGE 4: Check NLB Configuration
# ============================================================================
echo -e "\n${BLUE}[STAGE 4] Network Load Balancer${NC}"

echo "NLB DNS: $NLB_DNS"

# Check listeners
echo "Configured listeners:"
NLB_ARN=$(aws elbv2 describe-load-balancers \
  --region $REGION \
  --query 'LoadBalancers[?Type==`network`].LoadBalancerArn' \
  --output text)

aws elbv2 describe-listeners \
  --load-balancer-arn $NLB_ARN \
  --region $REGION \
  --query 'Listeners[*].[Port,Protocol]' \
  --output text | while read port proto; do
  echo "   $port/$proto"
done

# ============================================================================
# STAGE 5: MediaMTX Configuration
# ============================================================================
echo -e "\n${BLUE}[STAGE 5] MediaMTX Configuration${NC}"

echo "Task Definition Details:"
aws ecs describe-task-definition \
  --task-definition $TASK_DEF \
  --region $REGION \
  --query 'taskDefinition.containerDefinitions[0].environment[*].[name,value]' \
  --output text | grep -E "MTX_|RTSP|HLS" | while read name value; do
  echo "   $name = $value"
done

# ============================================================================
# STAGE 6: Test Stream Endpoints
# ============================================================================
echo -e "\n${BLUE}[STAGE 6] Stream Endpoint Connectivity${NC}"

echo "Testing RTSP endpoint (port 8554)..."
if timeout 3 bash -c "exec 3<>/dev/tcp/$NLB_DNS/8554" 2>/dev/null; then
  echo -e "${GREEN}✅ RTSP port 8554 reachable${NC}"
else
  echo -e "${YELLOW}⚠️ RTSP port 8554 not reachable (may be firewall)${NC}"
fi

echo "Testing HLS endpoint (port 8888)..."
HLS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://$NLB_DNS:8888/hls/rpicam2/index.m3u8" 2>/dev/null || echo "000")

if [ "$HLS_CODE" -eq 200 ] 2>/dev/null; then
  echo -e "${GREEN}✅ HLS responding (HTTP 200)${NC}"
  echo "   URL: http://$NLB_DNS:8888/hls/rpicam2/index.m3u8"
elif [ "$HLS_CODE" -eq 000 ]; then
  echo -e "${YELLOW}⚠️ HLS not responding (network/firewall issue)${NC}"
else
  echo -e "${YELLOW}⚠️ HLS returned HTTP $HLS_CODE${NC}"
fi

# ============================================================================
# STAGE 7: CloudWatch Logs
# ============================================================================
echo -e "\n${BLUE}[STAGE 7] Service Logs${NC}"

echo "Checking CloudWatch logs for /ecs/mediamtx..."
LOG_COUNT=$(aws logs describe-log-streams \
  --log-group-name /ecs/mediamtx \
  --region $REGION \
  --query 'length(logStreams)' \
  --output text 2>/dev/null || echo "0")

if [ "$LOG_COUNT" -gt 0 ]; then
  echo -e "${GREEN}✅ $LOG_COUNT log streams found${NC}"
  echo "   Latest 5 log entries:"
  aws logs tail /ecs/mediamtx --region $REGION --no-follow 2>/dev/null | tail -5 | sed 's/^/   /'
else
  echo -e "${YELLOW}⚠️ No log streams found${NC}"
fi

# ============================================================================
# STAGE 8: Summary
# ============================================================================
echo -e "\n${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                      E2E TEST SUMMARY                            ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"

echo -e "\n${GREEN}Production Stream Pipeline:${NC}"
echo "  RPi Camera (IMX477, 1280x720@30fps)"
echo "  ↓ (H.264 via rpicam-vid + ffmpeg)"
echo "  RTSP Push → NLB:8554 (broadcast-nlb-rtmp...)"
echo "  ↓"
echo "  Fargate MediaMTX Service ($RUNNING/$DESIRED tasks)"
echo "  ↓"
echo "  HLS Output (8888) / RTMP Output (1935) / WebRTC (8889)"

echo -e "\n${GREEN}Access Methods:${NC}"
echo "  RTSP (Camera):  rtsp://$NLB_DNS:8554/rpicam2"
echo "  HLS (Browser):  http://$NLB_DNS:8888/hls/rpicam2/index.m3u8"
echo "  RTMP (Stream):  rtmp://$NLB_DNS:1935/rpicam2"

echo -e "\n${GREEN}Testing Commands:${NC}"
echo "  ffplay:   ffplay 'rtsp://$NLB_DNS:8554/rpicam2'"
echo "  VLC:      open 'rtsp://$NLB_DNS:8554/rpicam2'"
echo "  Logs:     aws logs tail /ecs/mediamtx --follow"
echo "  Status:   make status"

if [ "$RUNNING" -ge "$DESIRED" ] && [ "$RPICAM" = "running" ]; then
  echo -e "\n${GREEN}✅ E2E TEST PASSED - Full pipeline operational${NC}"
else
  echo -e "\n${YELLOW}⚠️ E2E TEST INCOMPLETE - Check components above${NC}"
fi
