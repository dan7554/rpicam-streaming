#!/bin/bash

# Setup AWS NLB (Network Load Balancer) for RTSP Port 8554
# This script creates or configures a Network Load Balancer for the RTSP server
# since Application Load Balancers don't support TCP protocol

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
REGION="${AWS_REGION:-us-east-2}"
SERVICE_NAME="${ECS_SERVICE_NAME:-mediamtx-service}"
CLUSTER_NAME="${ECS_CLUSTER_NAME:-mediamtx-cluster}"
NLB_NAME="${NLB_NAME:-mediamtx-nlb-rtsp}"

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

# Get VPC and Subnets from running ECS tasks
log "Gathering infrastructure information..."

TASK_ARNS=$(aws ecs list-tasks \
    --cluster "$CLUSTER_NAME" \
    --service-name "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'taskArns[0]' \
    --output text 2>/dev/null)

if [ -z "$TASK_ARNS" ] || [ "$TASK_ARNS" = "None" ]; then
    error "No running tasks found for service $SERVICE_NAME"
fi

TASK_DETAIL=$(aws ecs describe-tasks \
    --cluster "$CLUSTER_NAME" \
    --tasks "$TASK_ARNS" \
    --region "$REGION")

VPC_ID=$(echo "$TASK_DETAIL" | jq -r '.tasks[0].attachments[]? | select(.type=="ElasticNetworkInterface") | .details[] | select(.name=="subnetId") | .value' | head -1 | xargs -I {} aws ec2 describe-subnets --subnet-ids {} --region "$REGION" --query 'Subnets[0].VpcId' --output text)

if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
    error "Could not determine VPC from running tasks"
fi

log "VPC: $VPC_ID"

# Get subnets
SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region "$REGION" \
    --query 'Subnets[*].SubnetId' \
    --output text)

if [ -z "$SUBNETS" ]; then
    error "Could not find subnets in VPC $VPC_ID"
fi

SUBNET_ARG=""
for SUBNET in $SUBNETS; do
    SUBNET_ARG="$SUBNET_ARG --subnets $SUBNET"
done

log "Subnets: $SUBNETS"

# Check if NLB already exists
log "Checking for existing NLB..."
NLB_ARN=$(aws elbv2 describe-load-balancers \
    --region "$REGION" \
    --query "LoadBalancers[?LoadBalancerName=='$NLB_NAME'].LoadBalancerArn" \
    --output text 2>/dev/null)

if [ -z "$NLB_ARN" ] || [ "$NLB_ARN" = "None" ]; then
    warn "NLB not found, creating..."
    
    NLB_ARN=$(aws elbv2 create-load-balancer \
        --name "$NLB_NAME" \
        --subnets $SUBNETS \
        --type network \
        --scheme internet-facing \
        --region "$REGION" \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text)
    
    if [ -z "$NLB_ARN" ] || [ "$NLB_ARN" = "None" ]; then
        error "Failed to create NLB"
    fi
    
    log "NLB created: $NLB_ARN"
    log "Waiting for NLB to be active (this may take a minute)..."
    sleep 30
else
    log "NLB found: $NLB_ARN"
fi

# Create target group
log "Creating target group..."
TG_ARN=$(aws elbv2 create-target-group \
    --name mediamtx-tg-rtsp \
    --protocol TCP \
    --port 8554 \
    --vpc-id "$VPC_ID" \
    --target-type ip \
    --health-check-protocol TCP \
    --health-check-port 8554 \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 10 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 2 \
    --region "$REGION" \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text 2>/dev/null || \
    aws elbv2 describe-target-groups \
        --region "$REGION" \
        --query "TargetGroups[?TargetGroupName=='mediamtx-tg-rtsp'].TargetGroupArn" \
        --output text)

if [ -z "$TG_ARN" ] || [ "$TG_ARN" = "None" ]; then
    error "Failed to create or find target group"
fi

log "Target group: $TG_ARN"

# Create listener
log "Creating NLB listener on port 8554..."
LISTENER_ARN=$(aws elbv2 create-listener \
    --load-balancer-arn "$NLB_ARN" \
    --protocol TCP \
    --port 8554 \
    --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
    --region "$REGION" \
    --query 'Listeners[0].ListenerArn' \
    --output text 2>/dev/null || \
    aws elbv2 describe-listeners \
        --load-balancer-arn "$NLB_ARN" \
        --region "$REGION" \
        --query "Listeners[?Port==\`8554\`].ListenerArn" \
        --output text)

if [ -z "$LISTENER_ARN" ] || [ "$LISTENER_ARN" = "None" ]; then
    error "Failed to create listener"
fi

log "Listener created: $LISTENER_ARN"

# Register ECS tasks with target group
log "Registering ECS tasks..."

TASK_ARNS=$(aws ecs list-tasks \
    --cluster "$CLUSTER_NAME" \
    --service-name "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'taskArns[]' \
    --output text 2>/dev/null)

REGISTERED_COUNT=0
for TASK_ARN in $TASK_ARNS; do
    TASK_DETAIL=$(aws ecs describe-tasks \
        --cluster "$CLUSTER_NAME" \
        --tasks "$TASK_ARN" \
        --region "$REGION")
    
    # Extract IP from task network interface
    TASK_IP=$(echo "$TASK_DETAIL" | jq -r '.tasks[0].attachments[]? | select(.type=="ElasticNetworkInterface") | .details[] | select(.name=="privateIPv4Address") | .value' 2>/dev/null | head -1)
    
    if [ -n "$TASK_IP" ] && [ "$TASK_IP" != "null" ]; then
        log "Registering task: $TASK_IP:8554"
        aws elbv2 register-targets \
            --target-group-arn "$TG_ARN" \
            --targets Id="$TASK_IP",Port=8554 \
            --region "$REGION" 2>/dev/null
        REGISTERED_COUNT=$((REGISTERED_COUNT + 1))
    fi
done

log "Registered $REGISTERED_COUNT task(s)"

# Get NLB DNS
NLB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$NLB_ARN" \
    --region "$REGION" \
    --query 'LoadBalancers[0].DNSName' \
    --output text)

echo ""
echo -e "${GREEN}✅ NLB setup complete!${NC}"
echo ""
echo "Summary:"
echo "  NLB: $NLB_NAME"
echo "  NLB DNS: $NLB_DNS"
echo "  Port: 8554"
echo "  Protocol: TCP"
echo "  Target Group: mediamtx-tg-rtsp"
echo ""
echo "Next steps:"
echo "  1. Update your DNS CNAME to point to: $NLB_DNS"
echo "     ./setup-dns-cname.sh stream.racetrackstreaming.com $NLB_DNS <hosted-zone-id>"
echo ""
echo "  2. Wait for DNS propagation (5-30 minutes)"
echo ""
echo "  3. Test connectivity:"
echo "     timeout 5 bash -c '</dev/tcp/stream.racetrackstreaming.com/8554' && echo 'Connected' || echo 'Failed'"
echo ""
echo "  4. Check target group health in AWS Console before starting stream"
echo ""
