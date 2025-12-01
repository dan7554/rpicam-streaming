# Broadcast System Containerization

This directory contains a containerized broadcast system with nginx reverse proxy, SSL/TLS support, and full build pipeline.

## Architecture

```
┌─────────────────────────────────────────┐
│   Client (HTTPS) / API Requests         │
└──────────────┬──────────────────────────┘
               │ :443
               ▼
┌─────────────────────────────────────────┐
│         Nginx (SSL/TLS Proxy)           │
├─────────────────────────────────────────┤
│  / → React SPA (static files)           │
│  /api/* → Express Server                │
│  /socket.io → WebSocket (Socket.io)     │
└──────────────┬──────────────────────────┘
               │ :3001
               ▼
┌─────────────────────────────────────────┐
│  Express Server (Node.js)               │
│  ├─ REST API Routes                     │
│  ├─ WebSocket Connections               │
│  └─ Service Managers                    │
└──────────────┬──────────────────────────┘
               │ :8889
               ▼
┌─────────────────────────────────────────┐
│      MediaMTX (RTSP/HLS/WebRTC)         │
└─────────────────────────────────────────┘
```

## File Structure

```
broadcast-system/
├── Dockerfile                 # Multi-stage build (client + server)
├── nginx.conf                # Nginx main configuration
├── nginx-ssl.conf            # Nginx SSL/TLS and reverse proxy setup
├── docker-entrypoint.sh      # Container startup script
├── .dockerignore             # Docker build optimization
├── certs/                    # SSL certificates directory (mounted)
│   ├── server.crt           # Self-signed or Let's Encrypt cert
│   └── server.key           # Private key
├── client/                   # React frontend (Vite)
│   ├── src/
│   ├── public/
│   ├── package.json
│   ├── vite.config.js
│   └── index.html
├── server/                   # Express.js backend
│   ├── index.js
│   ├── routes/
│   ├── services/
│   └── package.json
└── config/                   # Configuration files
    ├── cameras.json
    ├── scenes.json
    └── streaming.json
```

## Building the Container

### Build the Docker image

```bash
# From the repository root
docker build -f broadcast-system/Dockerfile -t broadcast-system:latest broadcast-system/

# Or using docker-compose
docker-compose build broadcast-system
```

### Multi-stage build process

1. **Stage 1 - Client Build (client-builder)**
   - Installs npm dependencies
   - Builds React/Vite application
   - Output: `/build/client/dist`

2. **Stage 2 - Server Build (server-builder)**
   - Installs npm dependencies
   - Prepares Node.js server
   - Output: `/build/node_modules`, `/build/server`

3. **Stage 3 - Runtime**
   - Base: Node.js 20 Alpine
   - Copies built client from stage 1
   - Copies built server from stage 2
   - Installs nginx
   - Configures nginx with SSL
   - Sets up entrypoint script

## Running the Container

### Using Docker Compose

```bash
# From repository root
docker-compose up broadcast-system

# In background
docker-compose up -d broadcast-system

# View logs
docker-compose logs -f broadcast-system

# Rebuild
docker-compose up --build broadcast-system
```

### Using Docker CLI

```bash
# Build
docker build -f broadcast-system/Dockerfile -t broadcast-system:latest broadcast-system/

# Run with self-signed certificates
docker run -d \
  --name broadcast \
  -p 80:80 \
  -p 443:443 \
  -e MEDIAMTX_URL=https://mediamtx.local:8889 \
  broadcast-system:latest

# Run with custom certificates
docker run -d \
  --name broadcast \
  -p 80:80 \
  -p 443:443 \
  -v /path/to/certs:/etc/nginx/certs:ro \
  -e MEDIAMTX_URL=https://mediamtx.local:8889 \
  broadcast-system:latest

# View logs
docker logs -f broadcast

# Shell access
docker exec -it broadcast sh
```

## SSL/TLS Certificates

### Self-signed Certificates (Default)

If no certificates are found, the entrypoint script automatically generates self-signed certificates:

```bash
/etc/nginx/certs/
├── server.crt  (365-day validity)
└── server.key
```

### Providing Custom Certificates

Mount your certificates at runtime:

```bash
docker run -d \
  -v ./broadcast-system/certs:/etc/nginx/certs:ro \
  broadcast-system:latest
```

Create the `broadcast-system/certs/` directory with:
- `server.crt` - Your SSL certificate
- `server.key` - Your private key

### Generating Self-signed Certificates

```bash
mkdir -p broadcast-system/certs

openssl req -x509 -newkey rsa:4096 \
  -keyout broadcast-system/certs/server.key \
  -out broadcast-system/certs/server.crt \
  -days 365 \
  -nodes \
  -subj "/C=US/ST=State/L=City/O=Organization/CN=yourdomain.com"

chmod 600 broadcast-system/certs/server.key
chmod 644 broadcast-system/certs/server.crt
```

### Using Let's Encrypt Certificates

```bash
# Generate with certbot
certbot certonly --standalone -d yourdomain.com

# Copy to broadcast-system/certs/
cp /etc/letsencrypt/live/yourdomain.com/fullchain.pem broadcast-system/certs/server.crt
cp /etc/letsencrypt/live/yourdomain.com/privkey.pem broadcast-system/certs/server.key

# Start container with mounted certs
docker-compose up broadcast-system
```

## Endpoints

All endpoints are served over HTTPS (port 443):

### Client Routes

```
GET  /                      → React SPA (index.html)
GET  /api/*                 → API requests
WS   /socket.io             → WebSocket connections
```

### API Routes (Express Server)

```
GET  /api/health            → Health check
GET  /api/cameras           → List cameras
POST /api/cameras/:id/*     → Camera control
GET  /api/scenes            → List scenes
POST /api/scenes/:id/*      → Scene management
WS   /api/socket.io         → Real-time updates
```

## Environment Variables

```bash
NODE_ENV=production              # Node.js environment
PORT=3001                        # Express server port (internal)
MEDIAMTX_URL=https://mediamtx:8889  # MediaMTX connection URL
```

## Networking

### With docker-compose

Services communicate through Docker networks:

- `broadcast-network` - Internal communication between nginx and Express
- `mediamtx-network` - Shared with MediaMTX service

Express server can reach MediaMTX via hostname:
```
https://mediamtx:8889
```

### Without docker-compose

Create a bridge network:

```bash
docker network create broadcast-network

# Start MediaMTX
docker run -d \
  --name mediamtx \
  --network broadcast-network \
  -e MEDIAMTX_URL=https://mediamtx:8889 \
  mediamtx:latest

# Start broadcast system
docker run -d \
  --name broadcast \
  --network broadcast-network \
  -p 80:80 \
  -p 443:443 \
  -e MEDIAMTX_URL=https://mediamtx:8889 \
  broadcast-system:latest
```

## Performance Tuning

### Nginx Optimization

Edit `nginx.conf` to adjust:

```nginx
worker_processes auto;           # CPU cores
worker_connections 1024;         # Per-worker limit
keepalive_timeout 65;            # Connection keep-alive
client_max_body_size 20M;        # Upload limit

# Rate limiting zones
limit_req_zone $binary_remote_addr zone=general:10m rate=50r/s;
limit_req_zone $binary_remote_addr zone=api:10m rate=100r/s;
```

### Node.js Memory

Set environment variable:

```bash
docker run -e NODE_OPTIONS="--max-old-space-size=512" broadcast-system:latest
```

### Gzip Compression

Enabled by default. Adjust in `nginx.conf`:

```nginx
gzip_comp_level 6;     # 1-9 (higher = slower but smaller)
```

## Logging

### Container Logs

```bash
# All logs
docker-compose logs broadcast-system

# Follow logs
docker-compose logs -f broadcast-system

# Nginx access logs
docker exec broadcast-system cat /var/log/nginx/access.log

# Nginx errors
docker exec broadcast-system cat /var/log/nginx/error.log

# Node.js errors
docker exec broadcast-system npm logs
```

### Volume Mounting Logs

```bash
docker run -d \
  -v ./logs:/var/log/nginx \
  broadcast-system:latest
```

## Troubleshooting

### Connection refused

```bash
# Check if services are running
docker-compose ps

# Check logs
docker-compose logs broadcast-system mediamtx

# Test connectivity
docker-compose exec broadcast-system curl -k https://localhost/health
```

### SSL certificate errors

```bash
# Verify certificates exist
docker exec broadcast-system ls -la /etc/nginx/certs/

# Check certificate expiration
docker exec broadcast-system openssl x509 -in /etc/nginx/certs/server.crt -text -noout | grep -A 2 "Validity"

# Regenerate certificates
docker-compose exec broadcast-system rm -f /etc/nginx/certs/server.*
docker-compose restart broadcast-system
```

### WebSocket connection issues

Ensure `/socket.io` endpoint is properly configured in nginx:

```bash
# Test WebSocket
docker exec broadcast-system curl -v http://localhost:3001/socket.io/
```

### Express server not starting

```bash
# Check Node.js installation
docker exec broadcast-system node --version

# Check dependencies
docker exec broadcast-system npm list --depth=0

# Manual start (debug)
docker exec -it broadcast-system node server/index.js
```

## Production Deployment

### Use Let's Encrypt with docker-compose

```yaml
# Override in docker-compose.override.yml
services:
  broadcast-system:
    environment:
      - SSL_CERT_FILE=/etc/letsencrypt/live/yourdomain.com/fullchain.pem
      - SSL_KEY_FILE=/etc/letsencrypt/live/yourdomain.com/privkey.pem
    volumes:
      - /etc/letsencrypt:/etc/letsencrypt:ro
```

### Docker Registry Push

```bash
# Tag image
docker tag broadcast-system:latest myregistry/broadcast-system:latest

# Push to registry
docker push myregistry/broadcast-system:latest

# Deploy
docker pull myregistry/broadcast-system:latest
docker run -d myregistry/broadcast-system:latest
```

### Kubernetes Deployment

See `k8s/deployment.yaml` for Kubernetes manifests.

## Development

### Local Development with docker-compose

```bash
# Use development override file
docker-compose -f docker-compose.yml -f docker-compose.dev.yml up

# Rebuild on code changes
docker-compose up --build
```

### Without Docker

For local development without containers:

```bash
# Install dependencies
npm install
cd client && npm install && cd ..

# Build client
npm run build:client

# Start server
npm start

# Or with nodemon for development
npm run dev

# Client separately (different terminal)
cd client && npm run dev
```

## Scaling

### Multiple replicas with docker-compose

```yaml
services:
  broadcast-system:
    deploy:
      replicas: 3
    # Configure load balancer...
```

### Kubernetes scaling

```bash
kubectl scale deployment broadcast-system --replicas=3
```

## Security Best Practices

1. **Use strong SSL/TLS certificates** - Don't use self-signed in production
2. **Keep images updated** - Rebuild regularly to get security patches
3. **Use secrets for sensitive data** - Don't hardcode in docker-compose
4. **Restrict network access** - Use security groups and network policies
5. **Enable HTTPS only** - HTTP redirects to HTTPS
6. **Add authentication** - Implement auth in Express routes
7. **Rate limiting** - Nginx rate limiting is enabled by default
8. **CORS restrictions** - Configure as needed in nginx

See `nginx-ssl.conf` for security headers.

## License

See parent repository LICENSE file.
