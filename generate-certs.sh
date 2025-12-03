#!/bin/bash

# Generate SSL certificates for broadcast system
# Usage: ./generate-certs.sh [domain] [days]

DOMAIN="${1:-admin.racetrackstreaming.com}"
DAYS="${2:-365}"
CERT_DIR="broadcast-system/certs"
COUNTRY="US"
STATE="CO"
CITY="Mountains"
ORG="Racetrack Streaming"
CN="$DOMAIN"

echo "🔐 Generating SSL certificate for $DOMAIN..."
echo "   Valid for $DAYS days"

# Create cert directory if it doesn't exist
mkdir -p "$CERT_DIR"

# Generate private key
echo "📝 Generating private key..."
openssl genrsa -out "$CERT_DIR/server.key" 2048 2>/dev/null

# Generate certificate signing request (CSR)
echo "📋 Generating certificate signing request..."
openssl req -new \
    -key "$CERT_DIR/server.key" \
    -out "$CERT_DIR/server.csr" \
    -subj "/C=$COUNTRY/ST=$STATE/L=$CITY/O=$ORG/CN=$CN" \
    2>/dev/null

# Generate self-signed certificate with SANs
echo "✍️  Generating self-signed certificate..."
openssl x509 -req -days $DAYS \
    -in "$CERT_DIR/server.csr" \
    -signkey "$CERT_DIR/server.key" \
    -out "$CERT_DIR/server.crt" \
    -extensions san \
    -extfile <(printf "subjectAltName=DNS:$DOMAIN,DNS:localhost,IP:127.0.0.1") \
    2>/dev/null

# Verify certificate
echo "✅ Certificate generated successfully!"
echo ""
echo "📍 Certificate details:"
openssl x509 -in "$CERT_DIR/server.crt" -text -noout | grep -E "Subject:|Not Before|Not After|DNS:" | head -5

# Copy to root directory for local docker-compose
echo ""
echo "📋 Copying certificates to root directory..."
cp "$CERT_DIR/server.crt" server.crt
cp "$CERT_DIR/server.key" server.key
echo "✅ Certificates copied to root: server.crt, server.key"

# Verify files exist
if [ -f "$CERT_DIR/server.crt" ] && [ -f "$CERT_DIR/server.key" ]; then
    echo ""
    echo "✅ All certificate files generated successfully!"
    echo "   Location: $CERT_DIR/server.{crt,key}"
    exit 0
else
    echo "❌ Certificate generation failed!"
    exit 1
fi
