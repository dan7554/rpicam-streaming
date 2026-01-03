#!/bin/sh
set -e

echo "📊 Estimating monthly costs (rough estimate). Adjust price vars as needed."
HOURS=$((24*30))

MEDIAMTX_RUNNING=$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$MEDIAMTX_SERVICE" --region "$AWS_REGION" --output json 2>/dev/null | jq -r '.services[0].runningCount // 0' 2>/dev/null || echo 0)
BROADCAST_RUNNING=$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$BROADCAST_SERVICE" --region "$AWS_REGION" --output json 2>/dev/null | jq -r '.services[0].runningCount // 0' 2>/dev/null || echo 0)

MEDIAMTX_CPU=${MEDIAMTX_CPU:-0}
MEDIAMTX_MEMORY=${MEDIAMTX_MEMORY:-0}
BROADCAST_CPU=${BROADCAST_CPU:-0}
BROADCAST_MEMORY=${BROADCAST_MEMORY:-0}

MEDIAMTX_VCPU=$(awk "BEGIN{printf \"%.6f\", ${MEDIAMTX_CPU}/1024}")
MEDIAMTX_MEMGB=$(awk "BEGIN{printf \"%.6f\", ${MEDIAMTX_MEMORY}/1024}")
BROADCAST_VCPU=$(awk "BEGIN{printf \"%.6f\", ${BROADCAST_CPU}/1024}")
BROADCAST_MEMGB=$(awk "BEGIN{printf \"%.6f\", ${BROADCAST_MEMORY}/1024}")

MEDIAMTX_TASK_MONTH=$(awk "BEGIN{printf \"%.4f\", (${MEDIAMTX_VCPU} * ${PRICE_FARGATE_VCPU_H} + ${MEDIAMTX_MEMGB} * ${PRICE_FARGATE_MEM_GB_H}) * ${HOURS} }")
BROADCAST_TASK_MONTH=$(awk "BEGIN{printf \"%.4f\", (${BROADCAST_VCPU} * ${PRICE_FARGATE_VCPU_H} + ${BROADCAST_MEMGB} * ${PRICE_FARGATE_MEM_GB_H}) * ${HOURS} }")

TOTAL_COMPUTE=$(awk "BEGIN{printf \"%.2f\", ${MEDIAMTX_TASK_MONTH} * ${MEDIAMTX_RUNNING} + ${BROADCAST_TASK_MONTH} * ${BROADCAST_RUNNING} }")

ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --region "$AWS_REGION" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "")
if [ -n "$ALB_ARN" ]; then
  ALB_COST=${ALB_MONTHLY_PRICE}
else
  ALB_COST=0
fi

ECR_REPOS=$(aws ecr describe-repositories --region "$AWS_REGION" --query 'repositories | length(@)' --output text 2>/dev/null || echo 0)
EC2_COUNT=$(aws ec2 describe-instances --filters "Name=tag:Service,Values=mediamtx" "Name=instance-state-name,Values=running" --region "$AWS_REGION" --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | wc -w | tr -d ' ' || echo 0)
EC2_COST=$(awk "BEGIN{printf \"%.2f\", ${EC2_COUNT} * ${EC2_MONTHLY_ESTIMATE_PER_INSTANCE}}")

GRAND_TOTAL=$(awk "BEGIN{printf \"%.2f\", ${TOTAL_COMPUTE} + ${ALB_COST} + ${EC2_COST} }")

echo "\n--- Monthly cost estimate (rough) ---"
echo "Fargate tasks:"
echo "  mediamtx: running=${MEDIAMTX_RUNNING}, per-task-month=${MEDIAMTX_TASK_MONTH} USD"
echo "  broadcast: running=${BROADCAST_RUNNING}, per-task-month=${BROADCAST_TASK_MONTH} USD"
echo "Compute subtotal: ${TOTAL_COMPUTE} USD"
echo "ALB: present=$( [ -n "$ALB_ARN" ] && echo yes || echo no ), estimate=${ALB_COST} USD"
echo "ECR repos: ${ECR_REPOS} (note: storage size unknown; per-GB-month=${ECR_GB_MONTHLY} USD)"
echo "EC2 instances (tagged Service=mediamtx): ${EC2_COUNT}, estimate=${EC2_COST} USD"
echo "------------------------------------"
echo "Estimated monthly total: ${GRAND_TOTAL} USD"
echo "(This is a rough estimate. Adjust price vars when running for more accurate results.)"
