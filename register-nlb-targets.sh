#!/bin/bash

# Register new Fargate task IPs with NLB target groups
# This script gets current running task IPs and registers them with all mediamtx target groups

REGION="us-east-1"
CLUSTER="broadcast-cluster"
SERVICE="mediamtx-service"

echo "📋 Registering current Fargate tasks with NLB target groups..."
echo ""

# Get current running task IPs
echo "🔍 Getting current task IPs..."
TASK_IPS=()

TASKS=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --region $REGION --query 'taskArns' --output text 2>/dev/null)

if [ -z "$TASKS" ]; then
  echo "❌ No tasks found"
  exit 1
fi

for TASK_ARN in $TASKS; do
  # Get the task details to extract the private IP
  TASK_JSON=$(aws ecs describe-tasks --cluster $CLUSTER --task "$TASK_ARN" --region $REGION --output json 2>/dev/null)
  
  # Extract private IP from attachment details
  IP=$(echo "$TASK_JSON" | jq -r '.tasks[0].attachments[0].details[] | select(.name == "privateIPv4Address") | .value' 2>/dev/null)
  
  if [ -n "$IP" ] && [ "$IP" != "null" ]; then
    TASK_IPS+=("$IP")
    echo "  Found: $IP"
  fi
done

if [ ${#TASK_IPS[@]} -eq 0 ]; then
  echo "❌ No task IPs found"
  exit 1
fi

echo ""
echo "✅ Found ${#TASK_IPS[@]} tasks"

# Register with all target groups
echo ""
echo "📝 Registering tasks with target groups..."

TARGET_GROUPS=("mediamtx-rtsp:8554" "mediamtx-rtmp:1935" "mediamtx-streaming:8888" "mediamtx-api:8890")

for TG_CONFIG in "${TARGET_GROUPS[@]}"; do
  TG_NAME="${TG_CONFIG%:*}"
  TG_PORT="${TG_CONFIG#*:}"
  
  echo ""
  echo "Target Group: $TG_NAME (port $TG_PORT)"
  
  # Get target group ARN
  TG_ARN=$(aws elbv2 describe-target-groups --region $REGION --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
  
  if [ -z "$TG_ARN" ] || [ "$TG_ARN" == "None" ]; then
    echo "  ⚠️ Target group not found"
    continue
  fi
  
  # Build targets list
  TARGETS=""
  for IP in "${TASK_IPS[@]}"; do
    if [ -z "$TARGETS" ]; then
      TARGETS="Id=$IP,Port=$TG_PORT"
    else
      TARGETS="$TARGETS Id=$IP,Port=$TG_PORT"
    fi
  done
  
  # Register targets
  echo "  Registering targets: $TARGETS"
  aws elbv2 register-targets --target-group-arn "$TG_ARN" --targets $TARGETS --region $REGION 2>&1 | grep -q "RegisterTargets" && echo "  ✅ Registered" || echo "  ⚠️ Already registered or error"
done

echo ""
echo "⏳ Waiting 10 seconds for health checks..."
sleep 10

echo ""
echo "📊 Final target health status:"
for TG_NAME in mediamtx-rtsp mediamtx-rtmp mediamtx-streaming; do
  echo ""
  echo "Target Group: $TG_NAME"
  TG_ARN=$(aws elbv2 describe-target-groups --region $REGION --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --region $REGION --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State]' --output table
done

echo ""
echo "✅ Registration complete!"
