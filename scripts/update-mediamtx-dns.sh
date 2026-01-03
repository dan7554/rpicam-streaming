#!/bin/bash

# Update Route53 DNS record for MediaMTX with current Fargate task public IP
# This allows the broadcast client to use a stable DNS name that auto-updates
# when the MediaMTX ECS task restarts (and gets a new public IP)

set -e

AWS_REGION="${AWS_REGION:-us-east-1}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-Z02374481ZZI6SAQXWXM}"  # racetrackstreaming.com hosted zone
MEDIAMTX_SUBDOMAIN="${MEDIAMTX_SUBDOMAIN:-mediamtx.racetrackstreaming.com}"
ECS_CLUSTER="${ECS_CLUSTER:-broadcast-cluster}"
ECS_SERVICE="${ECS_SERVICE:-mediamtx-service}"

echo "🔍 Updating Route53 record for $MEDIAMTX_SUBDOMAIN..."

# Get current MediaMTX task public IP
echo "  Querying ECS for MediaMTX task IP..."
MEDIAMTX_IP=$(aws ecs list-tasks \
  --cluster "$ECS_CLUSTER" \
  --service-name "$ECS_SERVICE" \
  --desired-status RUNNING \
  --region "$AWS_REGION" \
  --query 'taskArns[0]' \
  --output text 2>/dev/null | \
xargs -I {} aws ecs describe-tasks \
  --cluster "$ECS_CLUSTER" \
  --tasks {} \
  --region "$AWS_REGION" \
  --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' \
  --output text 2>/dev/null | \
xargs -I {} aws ec2 describe-network-interfaces \
  --network-interface-ids {} \
  --region "$AWS_REGION" \
  --query 'NetworkInterfaces[0].Association.PublicIp' \
  --output text 2>/dev/null)

if [ -z "$MEDIAMTX_IP" ] || [ "$MEDIAMTX_IP" = "None" ]; then
  echo "❌ Could not determine MediaMTX public IP"
  exit 1
fi

echo "  ✅ MediaMTX IP: $MEDIAMTX_IP"

# Check if HOSTED_ZONE_ID is placeholder
if [ "$HOSTED_ZONE_ID" = "Z0123456789ABC" ]; then
  echo "⚠️  HOSTED_ZONE_ID not configured. Please set it to your Route53 zone ID."
  echo "   Get your zone ID: aws route53 list-hosted-zones-by-name --region $AWS_REGION"
  exit 1
fi

# Create or update Route53 A record
echo "  Updating Route53 record..."
CHANGE_BATCH=$(cat <<EOF
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$MEDIAMTX_SUBDOMAIN",
        "Type": "A",
        "TTL": 60,
        "ResourceRecords": [
          {
            "Value": "$MEDIAMTX_IP"
          }
        ]
      }
    }
  ]
}
EOF
)

CHANGE_INFO=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "$CHANGE_BATCH" \
  --region "$AWS_REGION" \
  --query 'ChangeInfo.Id' \
  --output text 2>/dev/null)

if [ -n "$CHANGE_INFO" ]; then
  echo "  ✅ Route53 updated: $MEDIAMTX_SUBDOMAIN → $MEDIAMTX_IP"
  echo "  Change ID: $CHANGE_INFO"
else
  echo "⚠️  Route53 update may have failed. Check AWS console."
fi

echo ""
echo "✅ DNS update complete!"
echo "   Broadcast client can now use: http://$MEDIAMTX_SUBDOMAIN:8888"
