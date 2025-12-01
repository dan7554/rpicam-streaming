#!/bin/bash

# Setup AWS ALB Listener for RTSP Port 8554
# This script configures the Application Load Balancer to listen on port 8554
# and forward traffic to the MediaMTX ECS service

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
REGION="${AWS_REGION:-us-east-2}"
SERVICE_NAME="${ECS_SERVICE_NAME:-mediamtx}"
CLUSTER_NAME="${ECS_CLUSTER_NAME:-default}"
ALB_NAME="${ALB_NAME:-mediamtx-alb}"

log() {
    echo -e "${GREEN}✓${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
    exit 1
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Step 1: Get ALB ARN
log "Finding ALB..."
ALB_ARN=$(aws elbv2 describe-load-balancers \
    --names "$ALB_NAME" \
    --region "$REGION" \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text 2>/dev/null)

if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
    error "ALB '$ALB_NAME' not found in region $REGION"
fi

log "ALB ARN: $ALB_ARN"

# Step 2: Get Target Group ARN
log "Finding or creating target group..."
TG_ARN=$(aws elbv2 describe-target-groups \
    --region "$REGION" \
    --query "TargetGroups[?TargetGroupName=='mediamtx-tg-8554'].TargetGroupArn" \
    --output text 2>/dev/null)

if [ -z "$TG_ARN" ] || [ "$TG_ARN" = "None" ]; then
    warn "Target group 'mediamtx-tg-8554' not found, creating..."
    
    # Get VPC ID from ALB
    VPC_ID=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns "$ALB_ARN" \
        --region "$REGION" \
        --query 'LoadBalancers[0].VpcId' \
        --output text)
    
    if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
        error "Could not determine VPC ID from ALB"
    fi
    
    log "Creating target group in VPC: $VPC_ID"
    TG_ARN=$(aws elbv2 create-target-group \
        --name mediamtx-tg-8554 \
        --protocol TCP \
        --port 8554 \
        --vpc-id "$VPC_ID" \
        --target-type ip \
        --region "$REGION" \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text)
    
    if [ -z "$TG_ARN" ] || [ "$TG_ARN" = "None" ]; then
        error "Failed to create target group"
    fi
    
    log "Target group created: $TG_ARN"
else
    log "Target group found: $TG_ARN"
fi

# Step 3: Check if listener already exists
log "Checking for existing listener on port 8554..."
LISTENER_ARN=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$ALB_ARN" \
    --region "$REGION" \
    --query "Listeners[?Port==\`8554\`].ListenerArn" \
    --output text 2>/dev/null)

if [ -z "$LISTENER_ARN" ] || [ "$LISTENER_ARN" = "None" ]; then
    warn "No listener found on port 8554, creating..."
    
    LISTENER_ARN=$(aws elbv2 create-listener \
        --load-balancer-arn "$ALB_ARN" \
        --protocol TCP \
        --port 8554 \
        --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
        --region "$REGION" \
        --query 'Listeners[0].ListenerArn' \
        --output text)
    
    if [ -z "$LISTENER_ARN" ] || [ "$LISTENER_ARN" = "None" ]; then
        error "Failed to create listener"
    fi
    
    log "Listener created: $LISTENER_ARN"
else
    log "Listener already exists: $LISTENER_ARN"
    
    # Update the listener to point to our target group
    log "Updating listener to use target group..."
    aws elbv2 modify-listener \
        --listener-arn "$LISTENER_ARN" \
        --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
        --region "$REGION"
fi

# Step 4: Get ECS task IPs and register them with target group
log "Registering ECS tasks with target group..."

# Get ECS task ENIs from the service
TASK_ARNS=$(aws ecs list-tasks \
    --cluster "$CLUSTER_NAME" \
    --service-name "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'taskArns[]' \
    --output text 2>/dev/null)

if [ -z "$TASK_ARNS" ]; then
    warn "No running tasks found for service $SERVICE_NAME in cluster $CLUSTER_NAME"
    warn "Please ensure the ECS service has running tasks"
else
    # Get task details to extract IPs
    TASK_COUNT=0
    for TASK_ARN in $TASK_ARNS; do
        TASK_DETAILS=$(aws ecs describe-tasks \
            --cluster "$CLUSTER_NAME" \
            --tasks "$TASK_ARN" \
            --region "$REGION" \
            --query 'tasks[0]')
        
        # Extract IP from task network interface
        TASK_IP=$(echo "$TASK_DETAILS" | jq -r '.attachments[]? | select(.type=="ElasticNetworkInterface") | .details[] | select(.name=="privateIPv4Address") | .value' 2>/dev/null)
        
        if [ -n "$TASK_IP" ] && [ "$TASK_IP" != "null" ]; then
            log "Registering task IP: $TASK_IP"
            aws elbv2 register-targets \
                --target-group-arn "$TG_ARN" \
                --targets Id="$TASK_IP",Port=8554 \
                --region "$REGION" 2>/dev/null || warn "Could not register $TASK_IP"
            TASK_COUNT=$((TASK_COUNT + 1))
        fi
    done
    
    if [ $TASK_COUNT -gt 0 ]; then
        log "Registered $TASK_COUNT task(s)"
    fi
fi

# Step 5: Configure health check
log "Configuring health check..."
aws elbv2 modify-target-group \
    --target-group-arn "$TG_ARN" \
    --health-check-protocol TCP \
    --health-check-port 8554 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 2 \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 10 \
    --region "$REGION"

log "Health check configured"

echo ""
echo -e "${GREEN}✅ ALB listener setup complete!${NC}"
echo ""
echo "Summary:"
echo "  ALB: $ALB_NAME"
echo "  Port: 8554"
echo "  Protocol: TCP"
echo "  Target Group: mediamtx-tg-8554"
echo ""
echo "Next steps:"
echo "  1. Verify the target group health status in AWS Console"
echo "  2. Test connectivity: timeout 5 bash -c '</dev/tcp/stream.racetrackstreaming.com/8554'"
echo "  3. Start the rpicam stream when ready"
echo ""
