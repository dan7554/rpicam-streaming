#!/bin/bash
# Script to update broadcast task definition with current MediaMTX private IP

set -e

CLUSTER="broadcast-cluster"
REGION="us-east-1"
MEDIAMTX_SERVICE="mediamtx-service"

echo "🔍 Finding MediaMTX task private IP for internal VPC communication..."

# Get the MediaMTX task ARN
TASK_ARN=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$MEDIAMTX_SERVICE" --region "$REGION" 2>/dev/null | jq -r '.taskArns[0]')

if [ -z "$TASK_ARN" ] || [ "$TASK_ARN" = "null" ]; then
    echo "❌ No running MediaMTX task found"
    exit 1
fi

echo "📌 MediaMTX Task ARN: $TASK_ARN"

# Get the task details and extract private IP
MEDIAMTX_PRIVATE_IP=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" --region "$REGION" 2>/dev/null | \
    jq -r '.tasks[0].attachments[] | select(.name=="ElasticNetworkInterface") | .details[] | select(.name=="privateIPv4Address") | .value')

if [ -z "$MEDIAMTX_PRIVATE_IP" ] || [ "$MEDIAMTX_PRIVATE_IP" = "null" ]; then
    echo "❌ Could not extract private IP from task metadata"
    exit 1
fi

echo "✅ MediaMTX Private IP: $MEDIAMTX_PRIVATE_IP"

# Get the current broadcast task definition
echo "📋 Fetching current broadcast task definition..."
TASK_DEF=$(aws ecs describe-task-definition --task-definition broadcast-task --region "$REGION" 2>/dev/null)

if [ -z "$TASK_DEF" ]; then
    echo "❌ Could not fetch broadcast task definition"
    exit 1
fi

# Update the MEDIAMTX_HOST environment variable to use private IP
echo "🔄 Updating MEDIAMTX_HOST to private IP: $MEDIAMTX_PRIVATE_IP"
UPDATED_TASK_DEF=$(echo "$TASK_DEF" | jq ".taskDefinition.containerDefinitions[0].environment[] |= if .name == \"MEDIAMTX_HOST\" then .value = \"$MEDIAMTX_PRIVATE_IP\" else . end")

# Register the updated task definition
echo "📤 Registering updated task definition..."
NEW_TASK_DEF=$(aws ecs register-task-definition \
    --family broadcast-task \
    --container-definitions "$(echo "$TASK_DEF" | jq '.taskDefinition.containerDefinitions | map(if .name == "broadcast" then .environment |= map(if .name == "MEDIAMTX_HOST" then .value = "'"$MEDIAMTX_PRIVATE_IP"'" else . end) else . end)' -c)" \
    --task-role-arn "$(echo "$TASK_DEF" | jq -r '.taskDefinition.taskRoleArn // empty')" \
    --execution-role-arn "$(echo "$TASK_DEF" | jq -r '.taskDefinition.executionRoleArn')" \
    --network-mode "$(echo "$TASK_DEF" | jq -r '.taskDefinition.networkMode')" \
    --cpu "$(echo "$TASK_DEF" | jq -r '.taskDefinition.cpu')" \
    --memory "$(echo "$TASK_DEF" | jq -r '.taskDefinition.memory')" \
    --requires-compatibilities "$(echo "$TASK_DEF" | jq -r '.taskDefinition.requiresCompatibilities[]' -c)" \
    --region "$REGION" 2>/dev/null || true)

if [ -z "$NEW_TASK_DEF" ]; then
    echo "⚠️  Could not register new task definition (might already exist)"
else
    echo "✅ New task definition registered"
fi

echo "✅ Update complete. MediaMTX internal IP is now $MEDIAMTX_PRIVATE_IP"
echo "   The broadcast service will use this private IP to reach MediaMTX"
