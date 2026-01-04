#!/bin/bash
# Register broadcast task with target group and debug connectivity

set -e

TG_ARN="arn:aws:elasticloadbalancing:us-east-1:457553343935:targetgroup/broadcast-targets-80/315ab9895e4403ed"

echo "📋 Getting broadcast task information..."

# Get the broadcast task IP
TASK_ARN=$(aws ecs list-tasks --cluster broadcast-cluster --service-name broadcast-service --region us-east-1 --query 'taskArns[0]' --output text)

if [ -z "$TASK_ARN" ]; then
    echo "❌ No broadcast task found"
    exit 1
fi

echo "Task ARN: $TASK_ARN"

# Get the private IP from the task
TASK_IP=$(aws ecs describe-tasks \
  --cluster broadcast-cluster \
  --tasks "$TASK_ARN" \
  --region us-east-1 \
  --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value' \
  --output text)

echo "Task IP: $TASK_IP"

# Check current targets
echo ""
echo "📊 Current targets in broadcast-targets-80:"
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --region us-east-1 \
  --query 'TargetHealthDescriptions[*].[Target.Id, Target.Port, TargetHealth.State]' \
  --output table

# Register the target if not already registered
echo ""
echo "📌 Registering broadcast task with target group..."
aws elbv2 register-targets \
  --target-group-arn "$TG_ARN" \
  --targets Id="$TASK_IP",Port=80 \
  --region us-east-1

echo "✅ Target registered. Waiting 30 seconds for health check..."
sleep 30

# Check health
echo ""
echo "📊 Target health status:"
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --region us-east-1 \
  --query 'TargetHealthDescriptions[*].[Target.Id, TargetHealth.State, TargetHealth.ReasonCode, TargetHealth.Description]' \
  --output table

echo ""
echo "✅ Registration complete. Try accessing the ALB now."
