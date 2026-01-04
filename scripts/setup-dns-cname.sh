#!/bin/bash

# Cloudflare DNS CNAME Setup Script
# Creates CNAME records for broadcast subdomains pointing to ALB

set -e

# Configuration
DOMAIN="racetrackstreaming.com"
ADMIN_SUBDOMAIN="admin"
STREAM_SUBDOMAIN="stream"
MEDIAMTX_SUBDOMAIN="mediamtx"

# Get credentials from environment
if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    echo "⚠️  CLOUDFLARE_API_TOKEN not set - DNS records will not be configured"
    echo "   To configure DNS, run: export CLOUDFLARE_API_TOKEN='your-token'"
    exit 0
fi

if [ -z "$CLOUDFLARE_ZONE_ID" ]; then
    echo "⚠️  CLOUDFLARE_ZONE_ID not set - DNS records will not be configured"
    echo "   To configure DNS, run: export CLOUDFLARE_ZONE_ID='your-zone-id'"
    exit 0
fi

# Get ALB DNS name for broadcast services
ALB_DNS=$(aws elbv2 describe-load-balancers \
    --region us-east-1 \
    --query "LoadBalancers[?LoadBalancerName=='broadcast-alb'].DNSName" \
    --output text 2>/dev/null || echo "")

if [ -z "$ALB_DNS" ] || [ "$ALB_DNS" = "None" ]; then
    echo "❌ Could not find broadcast-alb DNS name"
    exit 1
fi

# Get NLB DNS name for MediaMTX (or fall back to ALB)
NLB_DNS=$(aws elbv2 describe-load-balancers \
    --region us-east-1 \
    --query "LoadBalancers[?LoadBalancerName=='mediamtx-nlb'].DNSName" \
    --output text 2>/dev/null || echo "")

if [ -z "$NLB_DNS" ] || [ "$NLB_DNS" = "None" ]; then
    echo "⚠️  MediaMTX NLB not found, using ALB for mediamtx subdomain"
    NLB_DNS="$ALB_DNS"
fi

echo "🔗 Setting up Cloudflare CNAME records..."
echo "   Broadcast ALB DNS: ${ALB_DNS}"
echo "   MediaMTX NLB DNS:  ${NLB_DNS}"
echo "   Zone: ${DOMAIN}"
echo ""

# Update each subdomain
for SUBDOMAIN in "$ADMIN_SUBDOMAIN" "$STREAM_SUBDOMAIN" "$MEDIAMTX_SUBDOMAIN"; do
    RECORD_NAME="${SUBDOMAIN}.${DOMAIN}"
    
    # Determine target and proxy setting based on subdomain
    if [ "$SUBDOMAIN" = "$MEDIAMTX_SUBDOMAIN" ]; then
        TARGET_DNS="$NLB_DNS"
        PROXIED="false"  # MediaMTX needs custom ports, so disable CF proxy
    else
        TARGET_DNS="$ALB_DNS"
        PROXIED="true"   # Broadcast uses standard HTTPS ports, so enable CF proxy
    fi
    
    echo "   ↳ Setting up ${RECORD_NAME}..."
    
    # Check if record already exists
    EXISTING_RECORD=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records?name=${RECORD_NAME}" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json" | jq -r '.result[0] // empty')
    
    if [ -n "$EXISTING_RECORD" ]; then
        RECORD_ID=$(echo "$EXISTING_RECORD" | jq -r '.id')
        RECORD_TYPE=$(echo "$EXISTING_RECORD" | jq -r '.type')
        CURRENT_CONTENT=$(echo "$EXISTING_RECORD" | jq -r '.content')
        
        if [ "$RECORD_TYPE" = "CNAME" ] && [ "$CURRENT_CONTENT" = "$TARGET_DNS" ]; then
            echo "     ✅ ${RECORD_NAME} already correct (CNAME → ${TARGET_DNS})"
            continue
        fi
        
        # Update existing record
        echo "     📝 Updating ${RECORD_NAME} from $RECORD_TYPE to CNAME..."
        RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${RECORD_ID}" \
            -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"type\":\"CNAME\",\"name\":\"${RECORD_NAME}\",\"content\":\"${TARGET_DNS}\",\"ttl\":3600,\"proxied\":${PROXIED}}")
        
        if echo "$RESPONSE" | jq -e '.success' > /dev/null 2>&1; then
            echo "     ✅ ${RECORD_NAME} → ${TARGET_DNS} (updated)"
        else
            ERROR=$(echo "$RESPONSE" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null)
            echo "     ❌ Failed to update ${RECORD_NAME}: ${ERROR}"
        fi
    else
        # Create new record
        echo "     ➕ Creating ${RECORD_NAME}..."
        RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records" \
            -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"type\":\"CNAME\",\"name\":\"${RECORD_NAME}\",\"content\":\"${TARGET_DNS}\",\"ttl\":3600,\"proxied\":${PROXIED}}")
        
        if echo "$RESPONSE" | jq -e '.success' > /dev/null 2>&1; then
            echo "     ✅ ${RECORD_NAME} → ${TARGET_DNS} (created)"
        else
            ERROR=$(echo "$RESPONSE" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null)
            echo "     ❌ Failed to create ${RECORD_NAME}: ${ERROR}"
        fi
    fi
done

echo ""
echo "✅ Cloudflare CNAME records setup complete!"
echo ""
echo "📝 Access via subdomains:"
echo "   • Admin Dashboard: https://${ADMIN_SUBDOMAIN}.${DOMAIN}"
echo "   • Stream Dashboard: https://${STREAM_SUBDOMAIN}.${DOMAIN}/hls/"
echo "   • MediaMTX API:     http://${MEDIAMTX_SUBDOMAIN}.${DOMAIN}:9997/v3/paths/list"
echo "   • MediaMTX RTSP:    rtsp://${MEDIAMTX_SUBDOMAIN}.${DOMAIN}:8554/stream"
echo "   • MediaMTX WebRTC:  http://${MEDIAMTX_SUBDOMAIN}.${DOMAIN}:8889/stream"
echo ""
echo "⏱️  DNS will propagate in 5-15 minutes (usually faster with Cloudflare)"
