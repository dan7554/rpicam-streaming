#!/bin/sh
# Docker entrypoint script for broadcast system
# Handles nginx startup, SSL certificate generation/validation, and Node server management

set -e

echo "🚀 Starting broadcast system..."

# Function to generate self-signed certificates if they don't exist
generate_certificates() {
    CERT_DIR="/etc/nginx/certs"
    CERT_FILE="$CERT_DIR/server.crt"
    KEY_FILE="$CERT_DIR/server.key"
    BROADCAST_HOSTNAME=${BROADCAST_HOSTNAME:-localhost}
    
    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        echo "📜 Generating self-signed SSL certificates for $BROADCAST_HOSTNAME..."
        mkdir -p "$CERT_DIR"
        
        openssl req -x509 -newkey rsa:4096 \
            -keyout "$KEY_FILE" \
            -out "$CERT_FILE" \
            -days 365 \
            -nodes \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=$BROADCAST_HOSTNAME"
        
        echo "✅ SSL certificates generated at $CERT_DIR"
        chmod 600 "$KEY_FILE"
        chmod 644 "$CERT_FILE"
    else
        echo "✅ SSL certificates found at $CERT_DIR"
    fi
}

# Function to wait for a service to be healthy
wait_for_service() {
    local service=$1
    local port=$2
    local max_attempts=30
    local attempt=0
    
    echo "⏳ Waiting for $service on port $port..."
    
    while [ $attempt -lt $max_attempts ]; do
        if nc -z localhost $port 2>/dev/null; then
            echo "✅ $service is ready"
            return 0
        fi
        
        attempt=$((attempt + 1))
        sleep 1
    done
    
    echo "❌ Timeout waiting for $service"
    return 1
}

# Step 1: Generate SSL certificates
generate_certificates

# Step 2: Create a health check endpoint handler in Express
# The Express server will serve /health at port 3001
echo "📦 Configuring Node server..."
export NODE_ENV=production
export PORT=3001

# Step 3: Start Express server in the background
echo "🌐 Starting Express server..."
cd /app
node server/index.js &
SERVER_PID=$!

# Trap signals to clean up
trap 'kill $SERVER_PID 2>/dev/null; kill $NGINX_PID 2>/dev/null; exit' SIGTERM SIGINT

# Wait for Express server to start
sleep 2
if ! wait_for_service "Express server" 3001; then
    echo "❌ Failed to start Express server"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
fi

# Step 4: Start nginx in foreground (for container logging)
BROADCAST_HOSTNAME=${BROADCAST_HOSTNAME:-localhost}
BROADCAST_PORT=${BROADCAST_PORT:-443}

echo "🔒 Starting nginx with SSL..."
echo "   HTTP:  http://$BROADCAST_HOSTNAME:80 → https://$BROADCAST_HOSTNAME:$BROADCAST_PORT"
echo "   Client: https://$BROADCAST_HOSTNAME/"
echo "   API:   https://$BROADCAST_HOSTNAME/api/*"
echo ""

# Verify nginx configuration
if ! nginx -t; then
    echo "❌ Nginx configuration test failed"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
fi

# Start nginx in foreground
nginx -g 'daemon off;' &
NGINX_PID=$!

# Show startup info
echo "✨ Broadcast system is ready!"
echo ""
echo "   📱 Web UI:     https://$BROADCAST_HOSTNAME"
echo "   🔌 API Base:   https://$BROADCAST_HOSTNAME/api"
echo "   🎥 MediaMTX:   $MEDIAMTX_URL"
echo ""

# Wait for both processes
wait $NGINX_PID
