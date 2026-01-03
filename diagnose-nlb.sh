#!/bin/bash
##############################################################################
# Diagnose NLB Network Connectivity Issue
# Purpose: Identify why NLB cannot reach running tasks
##############################################################################

set -e

REGION="us-east-1"
NLB_NAME="broadcast-nlb-rtmp"

echo "═══════════════════════════════════════════════════════════════════"
echo "NLB Network Connectivity Diagnostics"
echo "═══════════════════════════════════════════════════════════════════"

# Get NLB details
echo -e "\n[1] NLB Configuration"
NLB_ARN=$(aws elbv2 describe-load-balancers --region $REGION \
  --query "LoadBalancers[?contains(LoadBalancerName,'$NLB_NAME')].LoadBalancerArn" \
  --output text)

NLB_CONFIG=$(aws elbv2 describe-load-balancers --load-balancer-arns $NLB_ARN \
  --region $REGION --output json)

NLB_SUBNETS=$(echo "$NLB_CONFIG" | jq -r '.LoadBalancers[0].Subnets[0]')
NLB_VPC=$(echo "$NLB_CONFIG" | jq -r '.LoadBalancers[0].VpcId')
NLB_DNS=$(echo "$NLB_CONFIG" | jq -r '.LoadBalancers[0].DNSName')

echo "  NLB: $NLB_NAME"
echo "  DNS: $NLB_DNS"
echo "  VPC: $NLB_VPC"
echo "  Subnets: $(echo "$NLB_CONFIG" | jq -r '.LoadBalancers[0].Subnets | join(", ")')"

# Get task details
echo -e "\n[2] Running Task Configuration"
TASKS=$(aws ecs list-tasks --cluster broadcast-cluster \
  --service-name mediamtx-service --region $REGION --query 'taskArns' --output text)

if [ -z "$TASKS" ]; then
  echo "  ❌ No running tasks found"
  exit 1
fi

TASK_DETAILS=$(aws ecs describe-tasks --cluster broadcast-cluster \
  --tasks $TASKS --region $REGION --output json)

TASK_SUBNETS=$(echo "$TASK_DETAILS" | jq -r '.tasks[0].containerInstanceArn // .tasks[0].attachments[0] // "unknown"')
TASK_IPS=$(echo "$TASK_DETAILS" | jq -r '.tasks[*].containers[0].networkBindings[0].hostIp // .tasks[*].containers[0].networkInterfaces[0].privateIpAddress' | head -3)

echo "  Running tasks:"
echo "$TASK_DETAILS" | jq -r '.tasks[] | "    - \(.taskArn | split("/") | .[-1]) (\(.lastStatus))"'

echo "  Task IPs:"
echo "$TASK_IPS" | sed 's/^/    - /'

# Get subnet details
echo -e "\n[3] Subnet Analysis"
NLB_SUBNET_ID=$(aws elbv2 describe-load-balancers --load-balancer-arns $NLB_ARN \
  --region $REGION --query 'LoadBalancers[0].Subnets[0]' --output text)

SUBNET_DETAILS=$(aws ec2 describe-subnets --subnet-ids $NLB_SUBNET_ID \
  --region $REGION --output json)

SUBNET_AZ=$(echo "$SUBNET_DETAILS" | jq -r '.Subnets[0].AvailabilityZone')
SUBNET_CIDR=$(echo "$SUBNET_DETAILS" | jq -r '.Subnets[0].CidrBlock')

echo "  NLB Subnet: $NLB_SUBNET_ID"
echo "    - AZ: $SUBNET_AZ"
echo "    - CIDR: $SUBNET_CIDR"

# Check if tasks are in same subnets
echo -e "\n[4] Subnet Mismatch Check"
ALL_SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$NLB_VPC" \
  --region $REGION --output json)

echo "  All subnets in VPC $NLB_VPC:"
echo "$ALL_SUBNETS" | jq -r '.Subnets[] | "    - \(.SubnetId) (\(.AvailabilityZone)) \(.CidrBlock)"'

# Check route tables
echo -e "\n[5] Route Table Analysis"
ROUTE_TABLES=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$NLB_VPC" \
  --region $REGION --output json)

echo "  Route tables in VPC:"
echo "$ROUTE_TABLES" | jq -r '.RouteTables[] | "    - \(.RouteTableId)"'

echo -e "\n  Checking for NAT/Internet Gateway routes:"
echo "$ROUTE_TABLES" | jq -r '.RouteTables[] | 
  "    Route Table: \(.RouteTableId)\n" + 
  (.Routes[] | 
    if .DestinationCidrBlock or .DestinationIpv6CidrBlock then
      "      \(.DestinationCidrBlock // .DestinationIpv6CidrBlock) → \(.GatewayId // .NatGatewayId // .InstanceId // "unknown")"
    else empty end
  )'

# Check security groups
echo -e "\n[6] Security Group Analysis"
SG_ID=$(aws ecs describe-services --cluster broadcast-cluster \
  --services mediamtx-service --region $REGION \
  --query 'services[0].networkConfiguration.awsvpcConfiguration.securityGroups[0]' \
  --output text)

if [ "$SG_ID" != "None" ] && [ -n "$SG_ID" ]; then
  echo "  Task Security Group: $SG_ID"
  SG_RULES=$(aws ec2 describe-security-groups --group-ids $SG_ID \
    --region $REGION --output json)
  
  echo "  Inbound rules (ports relevant to NLB):"
  echo "$SG_RULES" | jq -r '.SecurityGroups[0].IpPermissions[] | 
    select(.FromPort >= 8500 and .FromPort <= 9999) |
    "    - Port \(.FromPort)-\(.ToPort) (\(.IpProtocol)) from \(.IpRanges[0].CidrIp // .UserIdGroupPairs[0].GroupId)"'
fi

# Check NLB target groups
echo -e "\n[7] NLB Target Group Status"
TG_ARNS=$(aws elbv2 describe-target-groups --region $REGION \
  --query "TargetGroups[?contains(TargetGroupName,'mediamtx')].TargetGroupArn" \
  --output text)

for TG_ARN in $TG_ARNS; do
  TG_NAME=$(aws elbv2 describe-target-groups --target-group-arns $TG_ARN \
    --region $REGION --query 'TargetGroups[0].TargetGroupName' --output text)
  
  TARGETS=$(aws elbv2 describe-target-health --target-group-arn $TG_ARN \
    --region $REGION --output json)
  
  echo "  Target Group: $TG_NAME"
  echo "    Health Check:"
  echo "$TARGETS" | jq -r '.TargetHealthDescriptions[0] | 
    "      Protocol: \(.TargetHealth.State) (port \(.Target.Port))"'
  
  echo "    Targets:"
  echo "$TARGETS" | jq -r '.TargetHealthDescriptions[] | 
    "      - \(.Target.Id) → \(.TargetHealth.State) (\(.TargetHealth.Reason // "healthy"))"'
done

# Network connectivity test
echo -e "\n[8] Connectivity Test (from host)"
echo "  Testing if NLB DNS resolves:"
NLB_IP=$(nslookup $NLB_DNS 2>/dev/null | grep "Address:" | head -2 | tail -1 | awk '{print $2}')
echo "    $NLB_DNS → $NLB_IP"

echo -e "\n[9] Diagnosis Summary"
echo "  ⚠️  NLB cannot reach tasks on ANY port (including TCP)"
echo "  This suggests:"
echo "    1. Network routing issue between NLB and task subnets"
echo "    2. OR tasks are in wrong subnets"
echo "    3. OR route tables missing routes"
echo "    4. OR security groups blocking NLB→task communication"
echo "    5. OR NLB needs to be in multi-AZ setup"

echo -e "\n[10] Recommended Next Steps"
echo "  1. Compare NLB subnets vs Task subnets in output above"
echo "  2. Check if NAT/IGW routes exist for task communication"
echo "  3. Verify security group allows NLB security group as source"
echo "  4. Consider rebuilding NLB with correct subnet configuration"

echo -e "\n═══════════════════════════════════════════════════════════════════\n"
