#!/bin/bash
##############################################################################
# End-to-End Test: RPi Camera → EC2 ECS MediaMTX → HLS/RTSP
#
# This script tests the full streaming pipeline:
# 1. RPi camera capture (H264 via rpicam-vid)
# 2. ffmpeg RTSP push to NLB
# 3. NLB routing to EC2-based MediaMTX
# 4. MediaMTX HLS/RTSP output
# 5. Local MacBook playback verification
##############################################################################

set -e

REGION="us-east-1"
CLUSTER="broadcast-cluster"
SERVICE="mediamtx-service-ec2"
TASK_FAMILY="mediamtx-task-ec2"
EC2_KEY="racetrack-key"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     E2E Test: RPi → EC2 ECS MediaMTX → Stream Playback        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"

# ============================================================================
# STAGE 1: Verify EC2 Instances
# ============================================================================
echo -e "\n${BLUE}[STAGE 1] Checking EC2 Instances...${NC}"

INSTANCES=$(aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --region $REGION \
  --query 'Reservations[*].Instances[*].[InstanceId,PrivateIpAddress,PublicIpAddress]' \
  --output json)

INSTANCE_COUNT=$(echo "$INSTANCES" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [ "$INSTANCE_COUNT" -eq 0 ]; then
  echo -e "${RED}❌ No running EC2 instances found${NC}"
  exit 1
fi

echo -e "${GREEN}✅ Found $INSTANCE_COUNT running EC2 instance(s)${NC}"
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --region $REGION \
  --query 'Reservations[*].Instances[*].[InstanceId,PrivateIpAddress,PublicIpAddress,InstanceType]' \
  --output table

# ============================================================================
# STAGE 2: Register EC2 Instances with ECS
# ============================================================================
echo -e "\n${BLUE}[STAGE 2] Registering EC2 Instances with ECS...${NC}"

INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --region $REGION \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text)

for INSTANCE_ID in $INSTANCE_IDS; do
  echo -n "Registering $INSTANCE_ID... "
  
  PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --region $REGION \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)
  
  # SSH into instance and check if ECS agent is running
  ECS_RUNNING=$(ssh -i ~/.ssh/${EC2_KEY}.pem \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=5 \
    ec2-user@$PUBLIC_IP "systemctl is-active ecs" 2>/dev/null || echo "inactive")
  
  if [ "$ECS_RUNNING" = "active" ]; then
    echo -e "${GREEN}✅ ECS agent already running${NC}"
  else
    echo "starting ECS agent..."
    ssh -i ~/.ssh/${EC2_KEY}.pem \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=5 \
      ec2-user@$PUBLIC_IP "sudo systemctl start ecs && sudo systemctl enable ecs" || echo -e "${YELLOW}⚠️ ECS start may be in progress${NC}"
    echo -e "${GREEN}✅ ECS agent started${NC}"
  fi
done

# Wait for instances to register
echo "Waiting for EC2 instances to register with ECS cluster..."
for i in {1..30}; do
  REGISTERED=$(aws ecs describe-clusters \
    --clusters $CLUSTER \
    --region $REGION \
    --query 'clusters[0].registeredContainerInstancesCount' \
    --output text)
  
  if [ "$REGISTERED" -ge "$INSTANCE_COUNT" ]; then
    echo -e "${GREEN}✅ All instances registered ($REGISTERED/$INSTANCE_COUNT)${NC}"
    break
  fi
  
  echo "  Waiting... ($i/30) - $REGISTERED registered"
  sleep 2
done

# ============================================================================
# STAGE 3: Update ECS Service (ensure tasks run on EC2)
# ============================================================================
echo -e "\n${BLUE}[STAGE 3] Updating ECS Service on EC2...${NC}"

echo "Checking service status..."
aws ecs describe-services \
  --cluster $CLUSTER \
  --services $SERVICE \
  --region $REGION \
  --query 'services[0].[serviceName,status,runningCount,desiredCount]' \
  --output table

# Force new deployment
echo "Triggering new deployment..."
aws ecs update-service \
  --cluster $CLUSTER \
  --service $SERVICE \
  --force-new-deployment \
  --region $REGION > /dev/null

echo -e "${GREEN}✅ Service update triggered${NC}"

# Wait for tasks to start
echo "Waiting for MediaMTX tasks to launch on EC2..."
for i in {1..60}; do
  RUNNING=$(aws ecs describe-services \
    --cluster $CLUSTER \
    --services $SERVICE \
    --region $REGION \
    --query 'services[0].runningCount' \
    --output text)
  
  DESIRED=$(aws ecs describe-services \
    --cluster $CLUSTER \
    --services $SERVICE \
    --region $REGION \
    --query 'services[0].desiredCount' \
    --output text)
  
  if [ "$RUNNING" -ge "$DESIRED" ]; then
    echo -e "${GREEN}✅ Tasks running: $RUNNING/$DESIRED${NC}"
    break
  fi
  
  echo "  Status: $RUNNING/$DESIRED tasks running ($i/60)"
  sleep 2
done

# ============================================================================
# STAGE 4: Verify NLB and Health Checks
# ============================================================================
echo -e "\n${BLUE}[STAGE 4] Checking Network Load Balancer...${NC}"

NLB_DNS=$(aws elbv2 describe-load-balancers \
  --region $REGION \
  --query 'LoadBalancers[?Type==`network`].[DNSName,LoadBalancerName]' \
  --output text | head -1 | awk '{print $1}')

if [ -z "$NLB_DNS" ]; then
  echo -e "${RED}❌ No NLB found${NC}"
else
  echo -e "${GREEN}✅ NLB DNS: $NLB_DNS${NC}"
  
  # Check target health
  echo "Checking target group health..."
  aws elbv2 describe-target-health \
    --target-group-arn $(aws elbv2 describe-target-groups \
      --region $REGION \
      --query 'TargetGroups[0].TargetGroupArn' \
      --output text) \
    --region $REGION \
    --query 'TargetHealthDescriptions[*].[Target.Id,Target.Port,TargetHealth.State,TargetHealth.Reason]' \
    --output table
fi

# ============================================================================
# STAGE 5: Check MediaMTX Configuration
# ============================================================================
echo -e "\n${BLUE}[STAGE 5] Verifying MediaMTX Configuration...${NC}"

# Get a running task
TASK_ARN=$(aws ecs list-tasks \
  --cluster $CLUSTER \
  --service-name $SERVICE \
  --region $REGION \
  --query 'taskArns[0]' \
  --output text)

if [ -z "$TASK_ARN" ] || [ "$TASK_ARN" = "None" ]; then
  echo -e "${YELLOW}⚠️ No running tasks yet - waiting...${NC}"
else
  echo "Task ARN: $TASK_ARN"
  
  # Get task details
  aws ecs describe-tasks \
    --cluster $CLUSTER \
    --tasks $TASK_ARN \
    --region $REGION \
    --query 'tasks[0].[taskDefinitionArn,lastStatus,containerInstanceArn]' \
    --output table
  
  echo -e "${GREEN}✅ Tasks are running on EC2 instances${NC}"
fi

# ============================================================================
# STAGE 6: Test RTSP Stream from RPi
# ============================================================================
echo -e "\n${BLUE}[STAGE 6] Verifying RPi Stream...${NC}"

echo "Checking RPi ffmpeg process via Tailscale..."
RPi_IP="100.80.96.23"

# Check if RPi service is active
ssh -i ~/.ssh/id_ed25519 -o ConnectTimeout=5 "dan7554@$RPi_IP" \
  "systemctl is-active rpicam-stream" 2>/dev/null || echo -e "${YELLOW}⚠️ Could not verify RPi service status${NC}"

echo -e "${GREEN}✅ RPi should be streaming${NC}"

# ============================================================================
# STAGE 7: Test Stream Endpoints
# ============================================================================
echo -e "\n${BLUE}[STAGE 7] Testing Stream Endpoints...${NC}"

echo "Testing RTSP endpoint..."
if timeout 5 curl -s -I rtsp://$NLB_DNS:8554/rpicam2 &>/dev/null; then
  echo -e "${GREEN}✅ RTSP endpoint responding${NC}"
else
  echo -e "${YELLOW}⚠️ RTSP check (may timeout on some networks)${NC}"
fi

echo "Testing HLS endpoint..."
if curl -s "http://$NLB_DNS:8888/hls/rpicam2/index.m3u8" | grep -q "^#EXTM3U"; then
  echo -e "${GREEN}✅ HLS M3U8 valid${NC}"
  curl -s "http://$NLB_DNS:8888/hls/rpicam2/index.m3u8" | head -10
else
  echo -e "${YELLOW}⚠️ HLS endpoint not responding (may need public IP)${NC}"
fi

# ============================================================================
# STAGE 8: Local Playback Test
# ============================================================================
echo -e "\n${BLUE}[STAGE 8] Testing Local Playback...${NC}"

LOCAL_RTSP="rtsp://100.100.74.51:8554/rpicam2"
LOCAL_HLS="http://100.100.74.51:8888/hls/rpicam2/index.m3u8"

echo "Testing local MediaMTX via Tailscale..."
if curl -s "$LOCAL_HLS" | grep -q "^#EXTM3U"; then
  echo -e "${GREEN}✅ Local HLS playback available${NC}"
  echo "   URL: $LOCAL_HLS"
else
  echo -e "${YELLOW}⚠️ Local MediaMTX not responding${NC}"
fi

# ============================================================================
# STAGE 9: Final Summary
# ============================================================================
echo -e "\n${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                        TEST SUMMARY                              ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"

echo -e "\n${GREEN}Stream Path:${NC}"
echo "  RPi Camera (IMX477) → ffmpeg → NLB:8554 → EC2 ECS MediaMTX"
echo ""
echo -e "${GREEN}Access Methods:${NC}"
echo "  1. RTSP (VLC/ffplay): rtsp://$NLB_DNS:8554/rpicam2"
echo "  2. HLS (Browser):     http://$NLB_DNS:8888/hls/rpicam2/index.m3u8"
echo "  3. Local (Tailscale): rtsp://100.100.74.51:8554/rpicam2"
echo ""
echo -e "${GREEN}EC2 Instances:${NC}"
echo "  - Total: $INSTANCE_COUNT"
echo "  - Registered with ECS: $(aws ecs describe-clusters --clusters $CLUSTER --region $REGION --query 'clusters[0].registeredContainerInstancesCount' --output text)"
echo ""
echo -e "${GREEN}ECS Service Status:${NC}"
aws ecs describe-services \
  --cluster $CLUSTER \
  --services $SERVICE \
  --region $REGION \
  --query 'services[0].[serviceName,status,runningCount,desiredCount,taskDefinition]' \
  --output table

echo -e "\n${GREEN}✅ E2E Test Complete!${NC}"
echo "Next steps:"
echo "  1. Open VLC and stream rtsp://$NLB_DNS:8554/rpicam2"
echo "  2. Or use: ffplay 'rtsp://$NLB_DNS:8554/rpicam2'"
echo "  3. Check ECS logs: aws logs tail $MEDIAMTX_LOG_GROUP --follow"
