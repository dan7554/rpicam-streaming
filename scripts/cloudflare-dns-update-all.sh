#!/bin/bash

# Cloudflare DNS Update Script - All Subdomains
# Updates all Cloudflare DNS A records with current ECS IP

set -e

# Configuration
DOMAIN="racetrackstreaming.com"
SUBDOMAINS=("admin" "rtsp" "webrtc" "hls")

# Get credentials from environment
if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    echo "❌ CLOUDFLARE_API_TOKEN environment variable not set"
    exit 1
fi

if [ -z "$CLOUDFLARE_ZONE_ID" ]; then
    echo "❌ CLOUDFLARE_ZONE_ID environment variable not set"
    exit 1
fi

# Get IP from argument or AWS
if [ -z "$1" ]; then
    echo "📍 Getting current ECS task IP from AWS..."
    TASK_ARN=$(aws ecs list-tasks --cluster broadcast-cluster --desired-status RUNNING \
        --region us-east-1 --query 'taskArns[0]' --output text)
    
    if [ "$TASK_ARN" = "None" ] || [ -z "$TASK_ARN" ]; then
        echo "❌ No running tasks found"
        exit 1
    fi
    
    NETWORK_INTERFACE_ID=$(aws ecs describe-tasks --cluster broadcast-cluster --tasks "$TASK_ARN" \
        --region us-east-1 --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' \
        --output text)
    
    if [ "$NETWORK_INTERFACE_ID" = "None" ] || [ -z "$NETWORK_INTERFACE_ID" ]; then
        echo "❌ No network interface found"
        exit 1
    fi
    
    NEW_IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$NETWORK_INTERFACE_ID" \
        --region us-east-1 --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
    
    if [ "$NEW_IP" = "None" ] || [ -z "$NEW_IP" ]; then
        echo "❌ No public IP found"
        exit 1
    fi
else
    NEW_IP="$1"
fi

echo "🔗 Updating all Cloudflare DNS records..."
echo "   Domain: ${DOMAIN}"
echo "   IP: ${NEW_IP}"
echo ""

# Update each subdomain
for SUBDOMAIN in "${SUBDOMAINS[@]}"; do
    RECORD_NAME="${SUBDOMAIN}.${DOMAIN}"
    echo "   ↳ Updating ${RECORD_NAME}..."
    
    # Get current DNS record ID
    RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records?name=${RECORD_NAME}&type=A" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
    
    if [ -z "$RECORD_ID" ]; then
        echo "     ⚠️  Record not found (skipping)"
        continue
    fi
    
    # Update DNS record
    RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${RECORD_ID}" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"A\",\"name\":\"${RECORD_NAME}\",\"content\":\"${NEW_IP}\",\"ttl\":60,\"proxied\":true}")
    
    if echo "$RESPONSE" | jq -e '.success' > /dev/null 2>&1; then
        echo "     ✅ ${RECORD_NAME} → ${NEW_IP}"
    else
        echo "     ❌ Failed to update ${RECORD_NAME}"
    fi
done

echo ""
echo "✅ Cloudflare DNS records updated successfully!"
echo ""
echo "⏱️  DNS will propagate in 5-15 minutes"
