# Multi-stage Dockerfile for broadcast system with nginx reverse proxy
# Build from repository root: docker build -f broadcast-system/Dockerfile -t broadcast-system:latest .

# Stage 1: Build the client (React/Vite app)
FROM --platform=linux/amd64 node:20-alpine AS client-builder

WORKDIR /build/client

# Copy client package files
COPY broadcast-system/client/package*.json ./

# Install dependencies
RUN npm install

# Fix rollup bindings issue
RUN rm -rf node_modules/.bin/@rollup && npm install @rollup/rollup-linux-x64-musl || true

# Copy client source
COPY broadcast-system/client/src ./src
COPY broadcast-system/client/public ./public
COPY broadcast-system/client/index.html ./
COPY broadcast-system/client/vite.config.js ./
COPY broadcast-system/client/vitest.config.js ./

# Build the client (rebuild rollup bindings for ARM64 if needed)
RUN npm run build

# Stage 2: Build the server (Express.js)
FROM --platform=linux/amd64 node:20-alpine AS server-builder

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
FROM node:20-alpine

# Install nginx and other tools for SSL support
RUN apk add --no-cache nginx openssl ca-certificates curl

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

# Create nginx directories
RUN mkdir -p /etc/nginx/certs /var/cache/nginx /var/log/nginx && \
    touch /var/log/nginx/access.log /var/log/nginx/error.log && \
    chown -R nginx:nginx /var/cache/nginx /var/log/nginx /etc/nginx

# Copy nginx configuration
COPY broadcast-system/nginx.conf /etc/nginx/nginx.conf
COPY broadcast-system/nginx-ssl.conf /etc/nginx/conf.d/default.conf

# Copy SSL certificates (will be overridden by volume in dev, used in production)
COPY broadcast-system/certs/server.crt /etc/nginx/certs/server.crt
COPY broadcast-system/certs/server.key /etc/nginx/certs/server.key

# Create entrypoint script
RUN mkdir -p /app/scripts
COPY broadcast-system/docker-entrypoint.sh /app/scripts/entrypoint.sh
RUN chmod +x /app/scripts/entrypoint.sh

# Expose ports
EXPOSE 80 443

# Environment variables
ENV NODE_ENV=production
ENV PORT=3001
ENV MEDIAMTX_URL=${MEDIAMTX_URL:-https://mediamtx:8889}

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

# Run entrypoint
ENTRYPOINT ["/app/scripts/entrypoint.sh"]
