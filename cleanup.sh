#!/bin/bash
echo "🧹 Final cleanup: Removing all remaining unhealthy targets..."

for TG_NAME in mediamtx-rtsp mediamtx-rtmp mediamtx-streaming mediamtx-api; do
  TG_ARN=$(aws elbv2 describe-target-groups --region us-east-1 --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text)
  
  echo ""
  echo "📌 $TG_NAME:"
  
  # Get unhealthy targets
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --region us-east-1 --query 'TargetHealthDescriptions[?TargetHealth.State!=`healthy`].[Target.Id,Target.Port]' --output text | while read ID PORT; do
    if [ ! -z "$ID" ]; then
      aws elbv2 deregister-targets --target-group-arn "$TG_ARN" --targets "Id=$ID,Port=$PORT" --region us-east-1 2>/dev/null
      echo "   ✓ Removed $ID:$PORT"
    fi
  done
done

echo ""
echo "✅ Cleanup complete!"
