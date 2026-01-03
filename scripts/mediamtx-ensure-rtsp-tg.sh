#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
VPC_ID="${AWS_VPC_ID:-}"
TG_NAME="mediamtx-rtsp"
PORT=8554

if [ -z "$VPC_ID" ]; then
  VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region "$REGION")
fi

# check if exists
TG_ARN=$(aws elbv2 describe-target-groups --region "$REGION" --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "")
if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
  echo "✅ Target group exists: $TG_ARN"
  exit 0
fi

echo "Creating RTSP target group '$TG_NAME' on port $PORT in VPC $VPC_ID..."
aws elbv2 create-target-group \
  --name "$TG_NAME" \
  --protocol TCP \
  --port $PORT \
  --vpc-id "$VPC_ID" \
  --target-type ip \
  --health-check-protocol TCP \
  --health-check-port "$PORT" \
  --health-check-enabled \
  --region "$REGION"

echo "✅ Created RTSP target group: $TG_NAME"
