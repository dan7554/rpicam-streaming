#!/bin/bash
##############################################################################
# Configure EC2 instances to register with ECS cluster
# - SSH into each instance
# - Update ECS agent configuration
# - Start/restart ECS service
##############################################################################

set -e

REGION="us-east-1"
CLUSTER="broadcast-cluster"

# Get instances with their public IPs
INSTANCES=$(aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --region $REGION \
  --query 'Reservations[*].Instances[*].[InstanceId,PublicIpAddress]' \
  --output text)

echo "🔌 Configuring EC2 instances for ECS cluster: $CLUSTER"
echo ""

# Check if we have instances
if [ -z "$INSTANCES" ]; then
  echo "❌ No instances found"
  exit 1
fi

# Check which key pair exists
KEY_PAIR="racetrack-key"
KEY_PATH="$HOME/.ssh/${KEY_PAIR}.pem"

if [ ! -f "$KEY_PATH" ]; then
  echo "❌ SSH key not found at $KEY_PATH"
  ls -la ~/.ssh/ | grep -E "\.pem|ed25519"
  echo ""
  echo "Try running: aws ec2 describe-key-pairs --region $REGION"
  exit 1
fi

echo "Using SSH key: $KEY_PATH"
echo ""

while IFS=$'\t' read -r INSTANCE_ID PUBLIC_IP; do
  [ -z "$INSTANCE_ID" ] && continue
  
  if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "None" ]; then
    echo "⚠️ No public IP for $INSTANCE_ID, trying private IP..."
    PUBLIC_IP=$(aws ec2 describe-instances \
      --instance-ids $INSTANCE_ID \
      --region $REGION \
      --query 'Reservations[0].Instances[0].PrivateIpAddress' \
      --output text)
  fi
  
  echo "Configuring $INSTANCE_ID ($PUBLIC_IP)..."
  
  # Create config script
  CONFIG_SCRIPT=$(cat << 'EOFCONFIG'
#!/bin/bash
# Update ECS configuration
sudo bash -c 'cat > /etc/ecs/ecs.config << EOFSETTINGS
ECS_CLUSTER=broadcast-cluster
ECS_ENABLE_CONTAINER_METADATA=true
ECS_AVAILABLE_LOGGING_DRIVERS=["json-file","awslogs"]
ECS_ENABLE_SPOT_INSTANCE_DRAINING=true
EOFSETTINGS'

# Restart ECS agent
sudo systemctl daemon-reload
sudo systemctl restart ecs
sudo systemctl status ecs

# Verify registration
sleep 10
echo "Checking registration..."
curl -s http://localhost:51678/v1/metadata | head -c 100
EOFCONFIG
)
  
  # SSH and run config
  ssh -i "$KEY_PATH" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o UserKnownHostsFile=/dev/null \
    ec2-user@$PUBLIC_IP "$CONFIG_SCRIPT" 2>&1 | head -20 || {
    echo "⚠️ SSH failed for $PUBLIC_IP, may need to wait for instance boot"
    continue
  }
  
  echo "✓ $INSTANCE_ID configured"
  echo "✓ $INSTANCE_ID configured"
  echo ""
done <<< "$INSTANCES"
echo "✅ Configuration sent to all instances"
echo ""
echo "Waiting 20 seconds for ECS agents to register..."
sleep 20

echo ""
echo "Checking registration status..."
REGISTERED=$(aws ecs describe-clusters \
  --clusters $CLUSTER \
  --region $REGION \
  --query 'clusters[0].registeredContainerInstancesCount' \
  --output text)

echo "Container instances registered: $REGISTERED"

if [ "$REGISTERED" -gt 0 ]; then
  echo "✅ EC2 instances registered!"
  
  # List them
  aws ecs list-container-instances \
    --cluster $CLUSTER \
    --region $REGION \
    --query 'containerInstanceArns' \
    --output table
else
  echo "⚠️ Still waiting for registration. This can take 30-60 seconds."
  echo ""
  echo "Check status with:"
  echo "  aws ecs describe-clusters --clusters $CLUSTER --region $REGION"
  echo ""
  echo "Check instance logs with:"
  echo "  ssh -i ~/.ssh/${KEY_PAIR}.pem ec2-user@<PUBLIC_IP>"
  echo "  sudo journalctl -u ecs -f"
fi
