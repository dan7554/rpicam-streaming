#!/bin/bash

# Cloudflare Setup for HTTPS
# Configures Cloudflare to provide free HTTPS for admin.racetrackstreaming.com

set -e

DOMAIN="racetrackstreaming.com"
SUBDOMAIN="admin"
RECORD_NAME="${SUBDOMAIN}.${DOMAIN}"
ALB_DNS="broadcast-alb-525661146.us-east-1.elb.amazonaws.com"

echo "🔒 Cloudflare HTTPS Setup"
echo "=========================="
echo ""

# Check if Cloudflare credentials are available
if [ -n "$CLOUDFLARE_API_TOKEN" ] && [ -n "$CLOUDFLARE_ZONE_ID" ]; then
    echo "✅ Cloudflare API credentials found"
    echo ""
    echo "This will automate the Cloudflare setup:"
    echo "  1. Create DNS record pointing to ALB"
    echo "  2. Enable Cloudflare proxy (orange cloud)"
    echo "  3. Verify DNS and SSL settings"
    echo ""
    
    read -p "Continue with automated setup? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        
        echo "📍 Creating DNS record in Cloudflare..."
        
        # Create or update DNS record
        # First, check if record exists
        RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records?name=${RECORD_NAME}&type=A" \
            -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
            -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
        
        if [ -z "$RECORD_ID" ]; then
            echo "   Creating new A record..."
            RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records" \
                -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{\"type\":\"A\",\"name\":\"${RECORD_NAME}\",\"content\":\"${ALB_DNS}\",\"ttl\":3600,\"proxied\":true}")
        else
            echo "   Updating existing A record..."
            RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${RECORD_ID}" \
                -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{\"type\":\"A\",\"name\":\"${RECORD_NAME}\",\"content\":\"${ALB_DNS}\",\"ttl\":3600,\"proxied\":true}")
        fi
        
        if echo "$RESPONSE" | jq -e '.success' > /dev/null 2>&1; then
            echo "   ✅ DNS record created/updated"
        else
            echo "   ❌ Failed to create DNS record"
            echo "   Response: $RESPONSE"
            exit 1
        fi
        
        echo ""
        echo "✅ Cloudflare setup complete!"
        echo ""
        echo "📝 Next steps:"
        echo "   1. Update nameservers in Route53 (AWS Console):"
        echo "      - Go to Route53 → Hosted zones → ${DOMAIN}"
        echo "      - Replace NS records with Cloudflare nameservers"
        echo "   2. Verify SSL setting in Cloudflare:"
        echo "      - Go to SSL/TLS → Overview"
        echo "      - Set mode to 'Flexible'"
        echo "   3. Wait 5-15 minutes for DNS propagation"
        echo ""
        echo "Test with:"
        echo "  curl -I https://${RECORD_NAME}/"
        exit 0
    fi
else
    echo "⚠️  Cloudflare API credentials not found"
    echo ""
    echo "To automate setup, set these environment variables:"
    echo "  export CLOUDFLARE_API_TOKEN='your-api-token'"
    echo "  export CLOUDFLARE_ZONE_ID='your-zone-id'"
    echo ""
fi

echo "📋 Manual Setup Guide"
echo "===================="
echo ""
echo "Step 1: Verify admin.racetrackstreaming.com is in Cloudflare"
echo "   URL: https://dash.cloudflare.com/"
echo "   If not added yet:"
echo "     - Click 'Add a Site'"
echo "     - Enter: ${DOMAIN}"
echo "     - Select 'Free' plan"
echo ""

echo "Step 2: Add DNS record in Cloudflare"
echo "   - Go to: DNS → Records"
echo "   - Click 'Add record'"
echo "   - Type: A"
echo "   - Name: ${SUBDOMAIN}"
echo "   - IPv4: ${ALB_DNS}"
echo "   - Proxy status: ☁️ Proxied (IMPORTANT - orange cloud)"
echo "   - TTL: Auto"
echo "   - Click Save"
echo ""

echo "Step 3: Update nameservers in Route53"
echo "   Route53 URL: https://console.aws.amazon.com/route53/"
echo "   - Click 'Hosted zones'"
echo "   - Select: ${DOMAIN}"
echo "   - Find the NS record"
echo "   - Replace with Cloudflare nameservers:"
echo "     (Cloudflare shows these during domain setup)"
echo ""

echo "Step 4: Enable Flexible SSL"
echo "   - Go to: SSL/TLS → Overview"
echo "   - Set encryption mode to: 'Flexible'"
echo "   - This allows:"
echo "     • Browser → Cloudflare: HTTPS"
echo "     • Cloudflare → ALB: HTTP (port 80)"
echo ""

echo "Step 5: Verify Setup (after 5-15 minutes)"
echo "   Check DNS resolution:"
echo "     nslookup ${RECORD_NAME}"
echo "   Should resolve to Cloudflare IPs (1.2.3.4 style, not AWS)"
echo ""
echo "   Test HTTPS access:"
echo "     curl -I https://${RECORD_NAME}/"
echo "   Should return 301 redirect to HTTPS"
echo ""
echo "   Check certificate:"
echo "     echo | openssl s_client -connect ${RECORD_NAME}:443 2>/dev/null | grep Issuer"
echo "   Should show: 'Cloudflare' or 'DigiCert'"
echo ""

echo "✅ Once verified, your admin dashboard will be at:"
echo "   https://admin.racetrackstreaming.com"
echo ""
