#!/bin/bash
##############################################################################
# Launch EC2 Instances for MediaMTX ECS
##############################################################################

set -e

REGION="us-east-1"
CLUSTER="broadcast-cluster"
KEY_NAME="mediamtx-ec2-key"
AMI="ami-0b3ca45933d9d6d87"  # ECS-optimized AMI us-east-1
INSTANCE_TYPE="t3.medium"
COUNT=2

echo "🚀 Launching $COUNT EC2 instances for MediaMTX..."
echo ""

# Get default VPC and subnet
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --region $REGION \
  --query 'Vpcs[0].VpcId' \
  --output text)

SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --region $REGION \
  --query 'Subnets[0].SubnetId' \
  --output text)

SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=default" \
  --region $REGION \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

echo "VPC: $VPC_ID"
echo "Subnet: $SUBNET_ID"
echo "Security Group: $SG_ID"
echo ""

# Launch instances with proper ECS configuration
LAUNCH_OUTPUT=$(aws ec2 run-instances \
  --image-id $AMI \
  --instance-type $INSTANCE_TYPE \
  --key-name $KEY_NAME \
  --security-group-ids $SG_ID \
  --subnet-id $SUBNET_ID \
  --iam-instance-profile Name=ecsInstanceProfile \
  --count $COUNT \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=mediamtx-ec2},{Key=Service,Value=mediamtx}]" \
  --user-data "$(cat << 'EOFUSERDATA' | base64 -w0
#!/bin/bash
exec > /var/log/ecs-startup.log 2>&1

echo "=== Starting ECS configuration at $(date) ==="

# Update ECS configuration BEFORE starting service
mkdir -p /etc/ecs
cat > /etc/ecs/ecs.config << 'EOFSETTINGS'
ECS_CLUSTER=broadcast-cluster
ECS_ENABLE_CONTAINER_METADATA=true
ECS_AVAILABLE_LOGGING_DRIVERS=["json-file","awslogs"]
ECS_ENABLE_SPOT_INSTANCE_DRAINING=true
ECS_ENABLE_TASK_IAM_ROLE=true
ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST=true
EOFSETTINGS

echo "ECS config set"

# Start Docker first
systemctl start docker
systemctl enable docker

# Start ECS with updated config
systemctl restart ecs
systemctl enable ecs

echo "ECS service started"
sleep 5

# Verify
curl -s http://localhost:51678/v1/metadata | head -c 100
echo ""
echo "=== ECS configuration complete at $(date) ==="
EOFUSERDATA
)" \
  --region $REGION \
  --output json)

echo "$LAUNCH_OUTPUT" > /tmp/launch.json

INSTANCE_IDS=$(echo "$LAUNCH_OUTPUT" | python3 -c "import sys, json; print(' '.join([i['InstanceId'] for i in json.load(sys.stdin)['Instances']]))")

echo "Launched instances: $INSTANCE_IDS"
echo ""

# Wait for instances to be running
echo "Waiting for instances to be running..."
for i in {1..60}; do
  RUNNING=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_IDS \
    --region $REGION \
    --query 'Reservations[*].Instances[*].State.Name' \
    --output text | grep -c "running" || true)
  
  if [ "$RUNNING" -eq "$COUNT" ]; then
    echo "✅ All instances running"
    break
  fi
  
  echo "  Running: $RUNNING/$COUNT ($i/60)"
  sleep 2
done

echo ""
aws ec2 describe-instances \
  --instance-ids $INSTANCE_IDS \
  --region $REGION \
  --query 'Reservations[*].Instances[*].[InstanceId,PrivateIpAddress,PublicIpAddress,State.Name]' \
  --output table

echo ""
echo "✅ Instances launched!"
echo ""
echo "Waiting 45 seconds for ECS agents to register..."
sleep 45

echo ""
REGISTERED=$(aws ecs describe-clusters \
  --clusters $CLUSTER \
  --region $REGION \
  --query 'clusters[0].registeredContainerInstancesCount' \
  --output text)

echo "Container instances registered: $REGISTERED/$COUNT"

if [ "$REGISTERED" -ge "$COUNT" ]; then
  echo "✅ All instances registered with ECS!"
else
  echo "⚠️ Instances still registering, waiting a bit more..."
  sleep 30
  REGISTERED=$(aws ecs describe-clusters \
    --clusters $CLUSTER \
    --region $REGION \
    --query 'clusters[0].registeredContainerInstancesCount' \
    --output text)
  echo "Container instances registered: $REGISTERED/$COUNT"
fi

aws ecs list-container-instances \
  --cluster $CLUSTER \
  --region $REGION \
  --query 'containerInstanceArns' \
  --output table
