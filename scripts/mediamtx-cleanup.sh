#!/bin/sh
set -e

echo "Deleting CloudWatch log groups..."
aws logs delete-log-group --log-group-name "$MEDIAMTX_LOG_GROUP" --region "$AWS_REGION" || true
aws logs delete-log-group --log-group-name "$BROADCAST_LOG_GROUP" --region "$AWS_REGION" || true

echo "Deleting ALB (listeners + target groups)..."
ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --region "$AWS_REGION" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "");
if [ -n "$ALB_ARN" ]; then
  for L in $(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --region "$AWS_REGION" --query 'Listeners[].ListenerArn' --output text 2>/dev/null || echo ""); do
    [ -n "$L" ] && aws elbv2 delete-listener --listener-arn "$L" --region "$AWS_REGION" || true
  done
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region "$AWS_REGION" || true
fi

for TGNAME in "$MEDIAMTX_TG_NAME" "$ALB_TG_NAME"; do
  TG_ARN=$(aws elbv2 describe-target-groups --names "$TGNAME" --region "$AWS_REGION" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "");
  if [ -n "$TG_ARN" ]; then
    aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region "$AWS_REGION" || true
  fi
done

echo "Revoking ALB->ECS SG ingress..."
aws ec2 revoke-security-group-ingress --group-id "$ECS_SECURITY_GROUP" --protocol tcp --port "$MEDIAMTX_PORT_API" --source-group "$ALB_SECURITY_GROUP" --region "$AWS_REGION" || true

echo "Deregistering task definitions..."
for FAM in "$MEDIAMTX_TASK_FAMILY" "$BROADCAST_TASK_FAMILY"; do
  for TD in $(aws ecs list-task-definitions --family-prefix "$FAM" --region "$AWS_REGION" --query 'taskDefinitionArns[]' --output text 2>/dev/null || echo ""); do
    [ -n "$TD" ] && aws ecs deregister-task-definition --task-definition "$TD" --region "$AWS_REGION" || true
  done
done

echo "Deleting ECR repositories..."
aws ecr delete-repository --repository-name "$MEDIAMTX_REPO" --force --region "$AWS_REGION" || true
aws ecr delete-repository --repository-name "$BROADCAST_REPO" --force --region "$AWS_REGION" || true

echo "Terminating EC2 instances tagged Service=mediamtx..."
INSTANCE_IDS=$(aws ec2 describe-instances --filters "Name=tag:Service,Values=mediamtx" "Name=instance-state-name,Values=running" --region "$AWS_REGION" --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "");
if [ -n "$INSTANCE_IDS" ]; then
  aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region "$AWS_REGION" || true
fi

echo "Attempting to delete security groups (best-effort)..."
aws ec2 revoke-security-group-ingress --group-id "$ALB_SECURITY_GROUP" --region "$AWS_REGION" --protocol all --port all --source-group "$ECS_SECURITY_GROUP" || true
aws ec2 revoke-security-group-ingress --group-id "$ECS_SECURITY_GROUP" --region "$AWS_REGION" --protocol all --port all --source-group "$ALB_SECURITY_GROUP" || true
aws ec2 delete-security-group --group-id "$ALB_SECURITY_GROUP" --region "$AWS_REGION" || true
aws ec2 delete-security-group --group-id "$ECS_SECURITY_GROUP" --region "$AWS_REGION" || true

echo "Scanning for resources tagged Service=mediamtx..."
RESOURCES=$(aws resourcegroupstaggingapi get-resources --tag-filters Key=Service,Values=mediamtx --region "$AWS_REGION" --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || echo "");
if [ -n "$RESOURCES" ]; then
  for R in $RESOURCES; do
    case "$R" in
      arn:aws:s3:::* )
        BUCKET=${R#arn:aws:s3:::}
        aws s3 rm s3://$BUCKET --recursive --region "$AWS_REGION" || true
        aws s3api delete-bucket --bucket $BUCKET --region "$AWS_REGION" || true
        ;;
      *nat-gateway/* )
        NATID=$(echo $R | awk -F/ '{print $NF}')
        aws ec2 delete-nat-gateway --nat-gateway-id $NATID --region "$AWS_REGION" || true
        ;;
      *allocation/* | *address/* )
        ALLOC=$(echo $R | sed -n 's/.*allocation\/\(eipalloc-[a-z0-9]*\).*/\1/p')
        [ -n "$ALLOC" ] && aws ec2 release-address --allocation-id $ALLOC --region "$AWS_REGION" || true
        ;;
      *ec2*instance/* )
        INST=$(echo $R | awk -F/ '{print $NF}')
        aws ec2 terminate-instances --instance-ids $INST --region "$AWS_REGION" || true
        ;;
      *elasticloadbalancing*loadbalancer/* )
        LBARN=$R
        aws elbv2 delete-load-balancer --load-balancer-arn "$LBARN" --region "$AWS_REGION" || true
        ;;
      *ecr*repository/* )
        REPO=$(echo $R | awk -F/ '{print $NF}')
        aws ecr delete-repository --repository-name $REPO --force --region "$AWS_REGION" || true
        ;;
      * )
        echo "Unhandled resource type: $R"
        ;;
    esac
  done
fi

echo "Full destructive cleanup completed (best-effort)."
