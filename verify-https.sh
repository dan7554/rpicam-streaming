#!/bin/bash

# Verify Cloudflare HTTPS Setup
# This script checks if your Cloudflare setup is working correctly

DOMAIN="racetrackstreaming.com"
RECORD_NAME="admin.${DOMAIN}"
ALB_DNS="broadcast-alb-525661146.us-east-1.elb.amazonaws.com"

echo "🔍 Verifying Cloudflare HTTPS Setup"
echo "===================================="
echo ""

# Check 1: DNS Resolution
echo "1️⃣  Checking DNS resolution..."
echo "   Testing: nslookup ${RECORD_NAME}"
DNS_RESULT=$(nslookup ${RECORD_NAME} 2>&1 | grep "Address:" | tail -1 | awk '{print $2}')

if [ -z "$DNS_RESULT" ]; then
    echo "   ❌ DNS not resolving"
    echo "      • Cloudflare nameservers may not be updated in Route53"
    echo "      • Wait 5-15 minutes and retry"
    DNS_OK=0
else
    echo "   ✅ DNS resolves to: ${DNS_RESULT}"
    
    # Check if it's a Cloudflare IP (not AWS)
    if [[ "$DNS_RESULT" =~ ^([0-9]+\.){3}[0-9]+$ ]]; then
        if ! [[ "$DNS_RESULT" == "98.94.236.43" ]] && ! [[ "$DNS_RESULT" == "3.225.56.46" ]]; then
            echo "      ✅ Pointing to Cloudflare (not AWS ALB IPs)"
            DNS_OK=1
        else
            echo "      ⚠️  Still pointing to AWS ALB (nameservers not updated yet)"
            DNS_OK=0
        fi
    fi
fi
echo ""

# Check 2: HTTPS Connectivity
echo "2️⃣  Checking HTTPS connectivity..."
echo "   Testing: curl -I https://${RECORD_NAME}/"

HTTPS_CHECK=$(timeout 5 curl -sI -k https://${RECORD_NAME}/ 2>&1 | head -1)

if echo "$HTTPS_CHECK" | grep -q "301\|200\|HTTP"; then
    echo "   ✅ HTTPS responding: $HTTPS_CHECK"
    HTTPS_OK=1
else
    echo "   ❌ HTTPS not responding"
    echo "      Response: $HTTPS_CHECK"
    echo "      • DNS may not be fully propagated"
    echo "      • ALB may not be responding to this domain"
    HTTPS_OK=0
fi
echo ""

# Check 3: SSL Certificate
echo "3️⃣  Checking SSL certificate..."
echo "   Testing: openssl s_client"

CERT_ISSUER=$(echo | timeout 5 openssl s_client -connect ${RECORD_NAME}:443 2>/dev/null | grep "issuer=" | sed 's/.*issuer=//')

if [ -z "$CERT_ISSUER" ]; then
    echo "   ❌ Could not retrieve certificate"
    echo "      • HTTPS may not be ready yet"
    echo "      • Or DNS may not be pointing to Cloudflare"
    CERT_OK=0
elif echo "$CERT_ISSUER" | grep -q "Cloudflare\|DigiCert"; then
    echo "   ✅ Valid certificate from: $CERT_ISSUER"
    CERT_OK=1
else
    echo "   ⚠️  Certificate issuer: $CERT_ISSUER"
    echo "      • May be a self-signed cert (if still on AWS)"
    CERT_OK=0
fi
echo ""

# Check 4: ALB Health
echo "4️⃣  Checking ALB health..."
echo "   Testing: curl http://ALB/health"

HEALTH_CHECK=$(curl -s -o /dev/null -w "%{http_code}" http://${ALB_DNS}/health)

if [ "$HEALTH_CHECK" == "200" ]; then
    echo "   ✅ ALB health check: ${HEALTH_CHECK} OK"
    HEALTH_OK=1
else
    echo "   ❌ ALB health check returned: ${HEALTH_CHECK}"
    HEALTH_OK=0
fi
echo ""

# Summary
echo "📋 SUMMARY"
echo "=========="
echo ""

if [ $DNS_OK -eq 1 ] && [ $HTTPS_OK -eq 1 ] && [ $CERT_OK -eq 1 ] && [ $HEALTH_OK -eq 1 ]; then
    echo "✅ All checks passed! Your HTTPS setup is complete!"
    echo ""
    echo "🎉 You can now access:"
    echo "   https://${RECORD_NAME}"
    echo ""
    exit 0
else
    echo "❌ Setup not complete yet. Status:"
    echo ""
    [ $DNS_OK -eq 1 ] && echo "   ✅ DNS configured" || echo "   ❌ DNS not configured"
    [ $HTTPS_OK -eq 1 ] && echo "   ✅ HTTPS responding" || echo "   ❌ HTTPS not responding"
    [ $CERT_OK -eq 1 ] && echo "   ✅ Valid certificate" || echo "   ❌ Certificate issue"
    [ $HEALTH_OK -eq 1 ] && echo "   ✅ ALB healthy" || echo "   ❌ ALB unhealthy"
    echo ""
    echo "📝 Next steps:"
    echo "   1. Follow instructions in ./HTTPS_SETUP.md"
    echo "   2. If DNS not configured: Update Route53 nameservers to Cloudflare"
    echo "   3. Wait 5-15 minutes for DNS propagation"
    echo "   4. Re-run this script to verify"
    echo ""
    exit 1
fi
