# Multi-stage Dockerfile for broadcast system with nginx reverse proxy
# Build from repository root: docker buildx build --platform linux/amd64 -f broadcast-system/Dockerfile -t broadcast-system:latest .
# For development: docker build -f broadcast-system/Dockerfile -t broadcast-system:latest .

# Stage 1: Build the client (React/Vite app)
FROM node:20-bookworm-slim AS client-builder

WORKDIR /build/client

# Copy client package files
COPY broadcast-system/client/package*.json ./

# Install dependencies with proper Python for native module builds
RUN npm install

# Install platform-specific rollup binary for linux/amd64 (AWS Fargate requirement)
# Always use x64 version for AWS deployment
RUN npm install --no-save @rollup/rollup-linux-x64-gnu || true

# Copy client source
COPY broadcast-system/client/src ./src
COPY broadcast-system/client/public ./public
COPY broadcast-system/client/index.html ./
COPY broadcast-system/client/vite.config.js ./
COPY broadcast-system/client/vitest.config.js ./

# Build the client
RUN npm run build

# Stage 2: Build the server (Express.js)
FROM node:20-bookworm-slim AS server-builder

WORKDIR /build

# Copy root package files (server dependencies)
COPY broadcast-system/package*.json ./

# Install dependencies
RUN npm ci

# Copy server source and config
COPY broadcast-system/server ./server
COPY broadcast-system/config ./config
COPY broadcast-system/scripts ./scripts

# Stage 3: Runtime - nginx + Node server
FROM node:20-bookworm-slim

# Install nginx, AWS CLI, and other tools for SSL support
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash nginx openssl ca-certificates curl netcat-openbsd python3 python3-pip && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    # Ensure nginx user exists (useradd will fail silently if already exists)
    useradd -r -s /bin/false nginx 2>/dev/null || true

WORKDIR /app

# Copy built client from builder stage
COPY --from=client-builder /build/client/build ./client/dist

# Copy server and dependencies from builder stage
COPY --from=server-builder /build/server ./server
COPY --from=server-builder /build/node_modules ./node_modules
COPY --from=server-builder /build/config ./config

# Copy package.json for reference
COPY broadcast-system/package.json ./

# Copy public assets (including HLS player)
COPY broadcast-system/public ./public

# Create nginx directories (run as root, nginx user created by package)
RUN mkdir -p /etc/nginx/certs /var/cache/nginx /var/log/nginx && \
    touch /var/log/nginx/access.log /var/log/nginx/error.log && \
    chmod 755 /etc/nginx/certs /var/cache/nginx /var/log/nginx

# Copy nginx configuration (with health check support)
RUN echo "Building with nginx health check support" && sleep 0
COPY broadcast-system/nginx.conf /etc/nginx/nginx.conf
COPY broadcast-system/nginx-ssl.conf /etc/nginx/conf.d/default.conf
# Verify file was copied
RUN ls -la /etc/nginx/conf.d/ && head -20 /etc/nginx/conf.d/default.conf

# Create entrypoint script
RUN mkdir -p /app/scripts

# Copy with explicit line ending handling for Alpine Linux compatibility
COPY broadcast-system/docker-entrypoint.sh /tmp/entrypoint.tmp
RUN tr -d '\r' < /tmp/entrypoint.tmp > /app/scripts/entrypoint.sh && \
    rm /tmp/entrypoint.tmp && \
    chmod +x /app/scripts/entrypoint.sh

# Expose ports
EXPOSE 80 443 8888

# Environment variables
ENV NODE_ENV=production
ENV PORT=3001
ENV MEDIAMTX_URL=${MEDIAMTX_URL:-https://mediamtx:8889}

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

# Run entrypoint
ENTRYPOINT ["/app/scripts/entrypoint.sh"]
