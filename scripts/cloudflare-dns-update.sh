#!/bin/bash

# Cloudflare DNS Update Script
# Updates Cloudflare DNS A record for admin.racetrackstreaming.com with current ECS IP

set -e

# Configuration
DOMAIN="racetrackstreaming.com"
SUBDOMAIN="admin"
RECORD_NAME="${SUBDOMAIN}.${DOMAIN}"

# Get credentials from environment or prompt
if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    echo "❌ CLOUDFLARE_API_TOKEN environment variable not set"
    echo ""
    echo "To set up Cloudflare API token:"
    echo "1. Go to: https://dash.cloudflare.com/profile/api-tokens"
    echo "2. Create token with 'Edit zone DNS' permission"
    echo "3. Export it: export CLOUDFLARE_API_TOKEN='your-token'"
    exit 1
fi

if [ -z "$CLOUDFLARE_ZONE_ID" ]; then
    echo "❌ CLOUDFLARE_ZONE_ID environment variable not set"
    echo ""
    echo "To find your Zone ID:"
    echo "1. Go to: https://dash.cloudflare.com/"
    echo "2. Click on ${DOMAIN}"
    echo "3. Zone ID is in the sidebar on the right"
    echo "4. Export it: export CLOUDFLARE_ZONE_ID='your-zone-id'"
    exit 1
fi

# Get IP from argument or AWS
if [ -z "$1" ]; then
    echo "📍 Getting current ECS task IP from AWS..."
    TASK_ARN=$(aws ecs list-tasks --cluster broadcast-cluster --desired-status RUNNING \
        --region us-east-2 --query 'taskArns[0]' --output text)
    
    if [ "$TASK_ARN" = "None" ] || [ -z "$TASK_ARN" ]; then
        echo "❌ No running tasks found"
        exit 1
    fi
    
    NETWORK_INTERFACE_ID=$(aws ecs describe-tasks --cluster broadcast-cluster --tasks "$TASK_ARN" \
        --region us-east-2 --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' \
        --output text)
    
    if [ "$NETWORK_INTERFACE_ID" = "None" ] || [ -z "$NETWORK_INTERFACE_ID" ]; then
        echo "❌ No network interface found"
        exit 1
    fi
    
    NEW_IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$NETWORK_INTERFACE_ID" \
        --region us-east-2 --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
    
    if [ "$NEW_IP" = "None" ] || [ -z "$NEW_IP" ]; then
        echo "❌ No public IP found"
        exit 1
    fi
else
    NEW_IP="$1"
fi

echo "🔗 Updating Cloudflare DNS..."
echo "   Domain: ${RECORD_NAME}"
echo "   IP: ${NEW_IP}"

# Get current DNS record ID
RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records?name=${RECORD_NAME}&type=A" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" | jq -r '.result[0].id // empty')

if [ -z "$RECORD_ID" ]; then
    echo "❌ DNS record not found in Cloudflare"
    echo ""
    echo "Please create the DNS record manually:"
    echo "1. Go to: https://dash.cloudflare.com/"
    echo "2. Click on ${DOMAIN}"
    echo "3. DNS records → Add record"
    echo "4. Type: A, Name: ${SUBDOMAIN}, IPv4: ${NEW_IP}"
    echo "5. Proxy status: Proxied (orange cloud)"
    exit 1
fi

# Update DNS record
RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${RECORD_ID}" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"A\",\"name\":\"${RECORD_NAME}\",\"content\":\"${NEW_IP}\",\"ttl\":60,\"proxied\":true}")

if echo "$RESPONSE" | jq -e '.success' > /dev/null 2>&1; then
    echo "✅ DNS record updated successfully!"
    echo "   Record: ${RECORD_NAME}"
    echo "   IP: ${NEW_IP}"
    echo ""
    echo "⏱️  DNS will propagate in 5-15 minutes"
    echo ""
    echo "Verify with:"
    echo "  nslookup ${RECORD_NAME}"
    echo "  curl -k https://${RECORD_NAME}/health"
else
    echo "❌ Failed to update DNS record"
    echo "Response: $RESPONSE"
    exit 1
fi
