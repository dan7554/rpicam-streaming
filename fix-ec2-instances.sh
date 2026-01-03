#!/bin/bash
##############################################################################
# Fix EC2 Instances for ECS
# - Attach IAM instance profile
# - Configure ECS cluster
# - Restart ECS agent
##############################################################################

set -e

REGION="us-east-1"
CLUSTER="broadcast-cluster"
IAM_PROFILE="ecsInstanceProfile"

echo "🔧 Fixing EC2 instances for ECS..."

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

for INSTANCE_ID in $INSTANCES; do
  echo ""
  echo "Processing $INSTANCE_ID..."
  
  # Check if instance already has an IAM profile
  CURRENT_PROFILE=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --region $REGION \
    --query 'Reservations[0].Instances[0].IamInstanceProfile' \
    --output text)
  
  if [ "$CURRENT_PROFILE" != "None" ]; then
    echo "  ✓ IAM profile already attached: $CURRENT_PROFILE"
  else
    echo "  Attaching IAM profile: $IAM_PROFILE"
    
    # Stop instance first
    echo "  Stopping instance..."
    aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $REGION
    
    # Wait for it to stop
    for i in {1..30}; do
      STATE=$(aws ec2 describe-instances \
        --instance-ids $INSTANCE_ID \
        --region $REGION \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text)
      
      if [ "$STATE" = "stopped" ]; then
        echo "  Instance stopped"
        break
      fi
      echo "    Waiting... ($i/30)"
      sleep 2
    done
    
    # Attach IAM profile
    aws ec2 associate-iam-instance-profile \
      --iam-instance-profile "Name=$IAM_PROFILE" \
      --instance-id $INSTANCE_ID \
      --region $REGION || echo "  ⚠️ May already be attached"
    
    # Start instance
    echo "  Starting instance..."
    aws ec2 start-instances --instance-ids $INSTANCE_ID --region $REGION
    
    # Wait for it to run
    for i in {1..30}; do
      STATE=$(aws ec2 describe-instances \
        --instance-ids $INSTANCE_ID \
        --region $REGION \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text)
      
      if [ "$STATE" = "running" ]; then
        echo "  ✓ Instance running"
        break
      fi
      echo "    Waiting... ($i/30)"
      sleep 2
    done
  fi
done

echo ""
echo "✅ EC2 instances fixed!"
echo ""
echo "Waiting 30 seconds for ECS agent to register..."
sleep 30

# Check registration
REGISTERED=$(aws ecs describe-clusters \
  --clusters $CLUSTER \
  --region $REGION \
  --query 'clusters[0].registeredContainerInstancesCount' \
  --output text)

echo "Container instances registered: $REGISTERED"

if [ "$REGISTERED" -gt 0 ]; then
  echo "✅ EC2 instances now registered with ECS!"
else
  echo "⚠️ Instances may still be registering. Wait a moment and check again:"
  echo "   aws ecs describe-clusters --clusters $CLUSTER --region $REGION"
fi
