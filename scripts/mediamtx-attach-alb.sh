#!/bin/sh
set -e

ALB_NAME=${ALB_NAME:-broadcast-alb}
AWS_REGION=${AWS_REGION:-us-east-1}
MEDIAMTX_TG_NAME=${MEDIAMTX_TG_NAME:-mediamtx-targets}
MEDIAMTX_PORT_API=${MEDIAMTX_PORT_API:-9997}

echo "🔗 Attaching mediamtx target group to ALB (${ALB_NAME})..."
ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --region "$AWS_REGION" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
  echo "❌ ALB $ALB_NAME not found (check ALB_NAME)"; exit 1
fi

echo "Found ALB: $ALB_ARN"

# Wait for ALB to become active
for i in $(seq 1 30); do
  ALB_STATE=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --region "$AWS_REGION" --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null || echo "");
  if [ "$ALB_STATE" = "active" ]; then break; fi
  echo "  Waiting for ALB to become active (state=$ALB_STATE) ($i/30)"; sleep 2
done
if [ "$ALB_STATE" != "active" ]; then echo "❌ ALB is not active (state=$ALB_STATE)"; exit 1; fi

TG_ARN=$(aws elbv2 describe-target-groups --region "$AWS_REGION" --names "$MEDIAMTX_TG_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)
if [ -z "$TG_ARN" ] || [ "$TG_ARN" = "None" ]; then
  echo "❌ Target group $MEDIAMTX_TG_NAME not found (run make mediamtx-create-target-group)"; exit 1
fi

echo "Found target group: $TG_ARN"

# Find existing listener for the API port
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --region "$AWS_REGION" --query 'Listeners[?Port==`'"$MEDIAMTX_PORT_API"'`].ListenerArn' --output text 2>/dev/null || true)
if [ -z "$LISTENER_ARN" ] || [ "$LISTENER_ARN" = "None" ]; then
  echo "📍 Creating listener on port $MEDIAMTX_PORT_API..."
  aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port "$MEDIAMTX_PORT_API" --default-actions Type=forward,TargetGroupArn="$TG_ARN" --region "$AWS_REGION"
  echo "  waiting for listener to initialize..."; sleep 2
else
  echo "🔁 Updating existing listener to forward to $TG_ARN"
  aws elbv2 modify-listener --listener-arn "$LISTENER_ARN" --default-actions Type=forward,TargetGroupArn="$TG_ARN" --region "$AWS_REGION"
fi

echo "✅ ALB listener configured (port $MEDIAMTX_PORT_API)"
