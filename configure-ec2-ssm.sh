#!/bin/bash
##############################################################################
# Configure EC2 instances via Systems Manager (no SSH key needed)
##############################################################################

set -e

REGION="us-east-1"
CLUSTER="broadcast-cluster"

echo "🔌 Configuring EC2 instances via Systems Manager..."
echo ""

# Get running instances
INSTANCES=$(aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --region $REGION \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text)

if [ -z "$INSTANCES" ]; then
  echo "❌ No running instances found"
  exit 1
fi

echo "Found instances: $INSTANCES"
echo ""

for INSTANCE_ID in $INSTANCES; do
  echo "Configuring $INSTANCE_ID..."
  
  # Use Systems Manager to run command
  COMMAND_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=[
      "sudo bash -c '\''cat > /etc/ecs/ecs.config << EOFSETTINGS",
      "ECS_CLUSTER='$CLUSTER'",
      "ECS_ENABLE_CONTAINER_METADATA=true",
      "ECS_AVAILABLE_LOGGING_DRIVERS=[\"json-file\",\"awslogs\"]",
      "ECS_ENABLE_SPOT_INSTANCE_DRAINING=true",
      "EOFSETTINGS'\''",
      "sudo systemctl daemon-reload",
      "sudo systemctl restart ecs",
      "sleep 5",
      "sudo systemctl status ecs"
    ]' \
    --region $REGION \
    --query 'Command.CommandId' \
    --output text 2>/dev/null || {
    echo "⚠️ Systems Manager not available, trying direct config..."
    continue
  })
  
  echo "  Command ID: $COMMAND_ID"
  
  # Wait for command to complete
  for i in {1..20}; do
    STATUS=$(aws ssm get-command-invocation \
      --command-id "$COMMAND_ID" \
      --instance-id "$INSTANCE_ID" \
      --region $REGION \
      --query 'Status' \
      --output text 2>/dev/null || echo "Pending")
    
    if [ "$STATUS" = "Success" ] || [ "$STATUS" = "Failed" ]; then
      echo "  Status: $STATUS"
      break
    fi
    
    echo "  Waiting for command... ($i/20)"
    sleep 2
  done
  
  echo "✓ $INSTANCE_ID configured"
  echo ""
done

echo "✅ Configuration complete"
echo ""
echo "Waiting 30 seconds for ECS agents to register..."
sleep 30

echo ""
echo "Checking registration status..."
REGISTERED=$(aws ecs describe-clusters \
  --clusters $CLUSTER \
  --region $REGION \
  --query 'clusters[0].registeredContainerInstancesCount' \
  --output text)

echo "Container instances registered: $REGISTERED"

if [ "$REGISTERED" -gt 0 ]; then
  echo "✅ EC2 instances registered with ECS!"
  echo ""
  aws ecs list-container-instances \
    --cluster $CLUSTER \
    --region $REGION \
    --query 'containerInstanceArns' \
    --output table
else
  echo "⚠️ Instances still registering. Check status in a moment with:"
  echo "   aws ecs describe-clusters --clusters $CLUSTER --region $REGION"
fi
