#!/bin/sh
set -e

ALB_NAME=${ALB_NAME:-broadcast-alb}
AWS_REGION=${AWS_REGION:-us-east-1}
AWS_VPC_ID=${AWS_VPC_ID:?}
ALB_SECURITY_GROUP_ENV=${ALB_SECURITY_GROUP:-}

echo "🛠 Ensuring ALB ${ALB_NAME} exists in ${AWS_REGION}..."
ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --region "$AWS_REGION" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  echo "✅ ALB exists: $ALB_ARN"
  exit 0
fi

# Find subnets
SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$AWS_VPC_ID" --region "$AWS_REGION" --query 'Subnets[].SubnetId' --output text 2>/dev/null || true)
if [ -z "$SUBNETS" ]; then
  echo "❌ No subnets found in VPC $AWS_VPC_ID"
  exit 1
fi
SUBNET_COUNT=$(echo "$SUBNETS" | wc -w)
if [ "$SUBNET_COUNT" -lt 2 ]; then
  echo "❌ Only $SUBNET_COUNT subnet(s) found in VPC $AWS_VPC_ID; ALB requires at least 2 subnets in different AZs. Create ALB manually or add subnets and re-run."
  exit 1
fi
# Pick first two subnets
SUBNET_PAIR=$(echo "$SUBNETS" | awk '{print $1, $2}')

# Ensure ALB security group
if [ -n "$ALB_SECURITY_GROUP_ENV" ]; then
  if aws ec2 describe-security-groups --group-ids "$ALB_SECURITY_GROUP_ENV" --region "$AWS_REGION" >/dev/null 2>&1; then
    ALB_SG="$ALB_SECURITY_GROUP_ENV"
    echo "Using existing ALB security group $ALB_SG"
  else
    echo "Warning: ALB_SECURITY_GROUP $ALB_SECURITY_GROUP_ENV not found; will create new SG."
    ALB_SG=""
  fi
fi

if [ -z "$ALB_SG" ]; then
  echo "➕ Creating ALB security group..."
  ALB_SG=$(aws ec2 create-security-group --group-name ${ALB_NAME}-sg --description "ALB SG for ${ALB_NAME}" --vpc-id "$AWS_VPC_ID" --region "$AWS_REGION" --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$AWS_REGION" >/dev/null 2>&1 || true
  aws ec2 authorize-security-group-egress --group-id "$ALB_SG" --protocol -1 --cidr 0.0.0.0/0 --region "$AWS_REGION" >/dev/null 2>&1 || true
  echo "✅ Created ALB security group $ALB_SG"
fi

# Create ALB
echo "Creating ALB ${ALB_NAME} in subnets: $SUBNET_PAIR"
ALB_ARN=$(aws elbv2 create-load-balancer --name "$ALB_NAME" --subnets $SUBNET_PAIR --security-groups "$ALB_SG" --scheme internet-facing --type application --region "$AWS_REGION" --query 'LoadBalancers[0].LoadBalancerArn' --output text)
if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
  echo "❌ Failed to create ALB $ALB_NAME"
  exit 1
fi

echo "✅ Created ALB $ALB_ARN"
# Print SG so caller can update Makefile if desired
echo "ALB_SG=$ALB_SG"
