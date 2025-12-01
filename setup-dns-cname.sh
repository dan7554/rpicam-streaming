#!/bin/bash
# Helper script to create DNS CNAME record
# Usage: ./setup-dns-cname.sh <domain> <alb-dns> <hosted-zone-id>

DOMAIN="${1:-stream.racetrackstreaming.com}"
ALB_DNS="$2"
ZONE_ID="$3"

# Trim whitespace
DOMAIN=$(echo "$DOMAIN" | xargs)
ALB_DNS=$(echo "$ALB_DNS" | xargs)
ZONE_ID=$(echo "$ZONE_ID" | xargs)

if [ -z "$ALB_DNS" ] || [ -z "$ZONE_ID" ]; then
    echo "❌ Missing parameters"
    echo "Usage: $0 <domain> <alb-dns> <hosted-zone-id>"
    exit 1
fi

echo "🔧 Creating CNAME record: $DOMAIN → $ALB_DNS"

# Create the DNS batch change
cat > /tmp/dns-batch.json << EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$DOMAIN",
      "Type": "CNAME",
      "TTL": 300,
      "ResourceRecords": [{"Value": "$ALB_DNS"}]
    }
  }]
}
EOF

# Apply the change
aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch file:///tmp/dns-batch.json

echo "✅ CNAME record created!"
echo "⏳ DNS propagation may take 5-30 minutes"

rm -f /tmp/dns-batch.json
