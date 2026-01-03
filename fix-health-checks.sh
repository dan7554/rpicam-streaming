#!/bin/bash
# Fix health check configuration for NLB targets

REGION="us-east-1"
TG_NAMES=("mediamtx-rtsp" "mediamtx-rtmp" "mediamtx-streaming" "mediamtx-api")

echo "🔧 Re-enabling health checks with corrected settings"
echo "="*60

for TG_NAME in "${TG_NAMES[@]}"; do
    echo "Configuring $TG_NAME..."
    
    TG_ARN=$(aws elbv2 describe-target-groups \
        --names "$TG_NAME" \
        --region "$REGION" \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text)
    
    # Set health checks: longer interval and timeout for stability
    aws elbv2 modify-target-group \
        --target-group-arn "$TG_ARN" \
        --region "$REGION" \
        --health-check-enabled \
        --health-check-protocol HTTP \
        --health-check-port 8890 \
        --health-check-path /v3/info \
        --health-check-interval-seconds 15 \
        --health-check-timeout-seconds 10 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 3 \
        2>&1 | grep -i "error" && echo "❌ Failed" || echo "✅ Updated"
done

echo ""
echo "Health checks reconfigured"
echo "="*60
