#!/usr/bin/env bash
set -euo pipefail

REGION=${1:-us-east-1}
CLUSTER=broadcast-cluster
SERVICE=mediamtx-service-ec2
SG_ID=sg-0a39a0404cc7eac61

echo "Region: $REGION"

echo "\n== ECS running tasks for $SERVICE =="
TASKS=$(aws ecs list-tasks --cluster $CLUSTER --service $SERVICE --desired-status RUNNING --region $REGION --query 'taskArns' --output text || true)
if [ -z "$TASKS" ] || [ "$TASKS" = "None" ]; then
  echo "No running tasks returned."
else
  aws ecs describe-tasks --cluster $CLUSTER --tasks $TASKS --region $REGION --query 'tasks[*].{taskArn:taskArn,lastStatus:lastStatus,desiredStatus:desiredStatus,containers:containers[*].{name:name,lastStatus:lastStatus,exitCode:exitCode}}' --output json || true
fi

echo "\n== ECS container instance (one) =="
CINST=$(aws ecs list-container-instances --cluster $CLUSTER --region $REGION --query 'containerInstanceArns[0]' --output text || true)
if [ -n "$CINST" ] && [ "$CINST" != "None" ]; then
  aws ecs describe-container-instances --cluster $CLUSTER --container-instances $CINST --region $REGION --query 'containerInstances[*].{ec2InstanceId:ec2InstanceId,agentConnected:agentConnected,runningTasksCount:runningTasksCount,version:version}' --output json || true
else
  echo "No container instances found."
fi

echo "\n== EC2 instance by tag Name=mediamtx-ec2 =="
INSTANCE_JSON=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=mediamtx-ec2" "Name=instance-state-name,Values=running" --region $REGION --query 'Reservations[0].Instances[0]' --output json || true)
if [ -z "$INSTANCE_JSON" ] || [ "$INSTANCE_JSON" = "null" ]; then
  echo "No running mediamtx-ec2 instance found."
  exit 0
fi
INSTANCE_ID=$(echo "$INSTANCE_JSON" | jq -r '.InstanceId')
PRIVATE_IP=$(echo "$INSTANCE_JSON" | jq -r '.PrivateIpAddress')
PUBLIC_IP=$(echo "$INSTANCE_JSON" | jq -r '.PublicIpAddress // empty')
echo "InstanceId: $INSTANCE_ID PrivateIP: $PRIVATE_IP PublicIP: $PUBLIC_IP"

echo "\n== Security group $SG_ID ingress rules =="
aws ec2 describe-security-groups --group-ids $SG_ID --region $REGION --query 'SecurityGroups[0].IpPermissions' --output json || true

echo "\n== Check SSM registration for instance =="
SSM_INFO=$(aws ssm describe-instance-information --region $REGION --query "InstanceInformationList[?InstanceId=='$INSTANCE_ID']" --output json || true)
if [ "$SSM_INFO" != "[]" ] && [ "$SSM_INFO" != "" ]; then
  echo "SSM available. Sending port check command (ss/netstat)..."
  CMD=$(aws ssm send-command --region $REGION --instance-ids $INSTANCE_ID --document-name "AWS-RunShellScript" --comment "Check mediamtx ports" --parameters commands=['ss -ltnp || netstat -tlnp'] --query Command.CommandId --output text)
  echo "CommandId: $CMD"
  for i in $(seq 1 20); do
    sleep 2
    STATUS=$(aws ssm get-command-invocation --command-id $CMD --instance-id $INSTANCE_ID --region $REGION --query Status --output text || echo "Pending")
    echo "Status: $STATUS"
    if [ "$STATUS" = "Success" ] || [ "$STATUS" = "Failed" ]; then
      break
    fi
  done
  echo "\n== Command output =="
  aws ssm get-command-invocation --command-id $CMD --instance-id $INSTANCE_ID --region $REGION --query 'StandardOutputContent' --output text || true
else
  echo "SSM not available. Testing TCP connectivity from this host to $PRIVATE_IP on ports 8554, 8888, 1935"
  for p in 8554 8888 1935; do
    if timeout 3 bash -c "</dev/tcp/$PRIVATE_IP/$p" 2>/dev/null; then
      echo "tcp/$p open"
    else
      echo "tcp/$p closed or unreachable"
    fi
  done
fi

echo "\n== Done =="
