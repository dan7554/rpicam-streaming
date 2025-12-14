#!/bin/bash
# Docker entrypoint script for broadcast system - Simplified
set -e

echo "🚀 Starting broadcast system..."

# Generate self-signed certificates
if [ ! -f "/etc/nginx/certs/server.crt" ]; then
    echo "📜 Generating SSL certificates..."
    mkdir -p /etc/nginx/certs
    openssl req -x509 -newkey rsa:4096 \
        -keyout /etc/nginx/certs/server.key \
        -out /etc/nginx/certs/server.crt \
        -days 365 -nodes \
        -subj "/C=US/ST=State/L=City/O=Org/CN=localhost"
    chmod 600 /etc/nginx/certs/server.key
    echo "✅ Certificates generated"
fi

# Start Express server
echo "🌐 Starting Express server..."
export NODE_ENV=production
export PORT=3001
cd /app
node server/index.js &
sleep 5
echo "✅ Express server started"

# Fix Nginx config if needed (remove HTTP->HTTPS redirect)
echo "🔧 Configuring Nginx..."

# Use localhost:8888 as fallback if MediaMTX service is not available via service discovery
# The resolver in nginx.conf will handle DNS lookups dynamically
MEDIAMTX_HOST="${MEDIAMTX_SERVICE_HOST:-localhost}"
MEDIAMTX_PORT="${MEDIAMTX_SERVICE_PORT:-8888}"

# Update the upstream server in the nginx config
sed -i "s|mediamtx-service.broadcast-cluster.ecs.local:8888|${MEDIAMTX_HOST}:${MEDIAMTX_PORT}|g" /etc/nginx/conf.d/default.conf

# Also remove any HTTP->HTTPS redirects to prevent ALB loops
if grep -q "return 301 https" /etc/nginx/conf.d/default.conf 2>/dev/null; then
    echo "   ⚠️  Removing redirect from Nginx..."
    sed -i '/return 301 https/d' /etc/nginx/conf.d/default.conf 2>/dev/null || true
fi

echo "   ✅ MediaMTX upstream: ${MEDIAMTX_HOST}:${MEDIAMTX_PORT}"

# Start Nginx
echo "🔒 Starting Nginx..."
echo ""
echo "   SSL/TLS chain: Internet → Cloudflare → ALB:443 → ALB:80 → Nginx → Apps"
echo "   ALB handles HTTPS termination and health checks"
echo ""

# Note: Skip nginx -t test as DNS resolution may not be available for service discovery at startup
# Nginx will validate the config when it tries to load it
# if ! nginx -t 2>&1; then
#     echo "⚠️  Nginx config test skipped (service discovery may not be available yet)"
# fi

echo "✨ Broadcast system ready!"
echo "   Web UI:  https://admin.racetrackstreaming.com"
echo "   Streams: https://stream.racetrackstreaming.com/hls/"
echo ""

# Start Nginx as PID 1
exec nginx -g 'daemon off;'
