# Broadcast System Container Architecture - Visual Guide

## Complete System Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        External Users / Browsers                        │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │
                    HTTP/HTTPS (Port 80/443)
                               │
                ┌──────────────▼──────────────┐
                │   Docker Network: Public    │
                │  (Port 80 & 443 Published)  │
                └──────────────┬──────────────┘
                               │
                ┌──────────────▼─────────────────────────────────────────┐
                │                                                        │
                │  ╔════════════════════════════════════════════════╗   │
                │  ║         NGINX (Reverse Proxy)                 ║   │
                │  ║                                               ║   │
                │  ║  • SSL/TLS Termination (443)                 ║   │
                │  ║  • HTTP Redirect to HTTPS (80→443)           ║   │
                │  ║  • Static File Serving                       ║   │
                │  ║  • Path-based Routing                        ║   │
                │  ║  • Gzip Compression                          ║   │
                │  ║  • Rate Limiting                             ║   │
                │  ║  • Security Headers (HSTS, CSP, etc)         ║   │
                │  ╠════════════════════════════════════════════════╣   │
                │  ║ GET  /                   → Client (React SPA)  ║   │
                │  ║ GET  /api/*              → Express Server      ║   │
                │  ║ WS   /socket.io          → WebSocket           ║   │
                │  ╚════════════════════════════════════════════════╝   │
                │                      │                                │
                │         ┌────────────┼────────────┐                  │
                │         │            │            │                  │
                │  ┌──────▼──┐  ┌──────▼────┐  ┌──────▼────┐          │
                │  │ Static  │  │  Express  │  │ WebSocket│          │
                │  │  Files  │  │  Server   │  │  Handler │          │
                │  │(dist)   │  │ (API)     │  │(Socket.io)          │
                │  └─────────┘  └──────┬────┘  └──────┬────┘          │
                │                      │             │                │
                │                      └──────┬──────┘                │
                │                             │                       │
                │                    ┌────────▼────────┐              │
                │                    │  Express Service│              │
                │                    │                 │              │
                │  ╔════════════════════════════════════════════╗    │
                │  ║      Docker Container: broadcast-system    ║    │
                │  ║                                            ║    │
                │  ║  • Node.js 20 Alpine                      ║    │
                │  ║  • Nginx                                  ║    │
                │  ║  • Express.js 4                           ║    │
                │  ║  • Socket.io 4                            ║    │
                │  ║  • React 18 (static dist)                 ║    │
                │  ║                                            ║    │
                │  ║  Ports:                                    ║    │
                │  ║  • 80 (HTTP)                              ║    │
                │  ║  • 443 (HTTPS)                            ║    │
                │  ║  • 3001 (Express - internal only)         ║    │
                │  ╚════════════════════════════════════════════╝    │
                │                      │                                │
                └──────────────────────┼────────────────────────────────┘
                                       │
                            HTTPS :8889 (Internal)
                                       │
                 ┌─────────────────────▼──────────────────────┐
                 │                                            │
                 │  ╔════════════════════════════════════════╗│
                 │  ║   Docker Container: mediamtx-server    ║│
                 │  ║                                        ║│
                 │  ║   MediaMTX Streaming Server           ║│
                 │  ║                                        ║│
                 │  ║   Ports:                               ║│
                 │  ║   • 8554 (RTSP - from RPi)            ║│
                 │  ║   • 8888 (HLS - HTTP)                 ║│
                 │  ║   • 8889 (WebRTC - HTTPS)             ║│
                 │  ║   • 9997 (API)                        ║│
                 │  ║   • 1935 (RTMP)                       ║│
                 │  ║   • 9996 (SRT)                        ║│
                 │  ╚════════════════════════════════════════╝│
                 │                                            │
                 └──────────────────┬───────────────────────────┘
                                    │
                    RTSP :8554 (from remote RPi)
                                    │
                    ┌───────────────▼─────────────┐
                    │  Raspberry Pi (Remote)      │
                    │  ├─ rpicam-vid              │
                    │  ├─ ffmpeg                  │
                    │  └─ DNS Resolution (8.8.8.8)
                    └─────────────────────────────┘
```

## Docker Network Layout

```
┌──────────────────────────────────────────────────────────────┐
│                      Docker Bridge Networks                  │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │         Network: mediamtx-network                   │   │
│  │  (Shared between mediamtx and broadcast-system)     │   │
│  ├──────────────────────────────────────────────────────┤   │
│  │  broadcast-system ────────► mediamtx:8889           │   │
│  │  (Can reach MediaMTX internally)                     │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │         Network: broadcast-network                  │   │
│  │  (For future broadcast service routing)             │   │
│  ├──────────────────────────────────────────────────────┤   │
│  │  (Currently only broadcast-system is in this net)    │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

## Multi-Stage Docker Build Process

```
┌─────────────────────────────────────────────────────────────┐
│              Docker Build Process (Multi-Stage)             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Stage 1: CLIENT BUILDER                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Base Image: node:20-alpine                         │   │
│  │ 1. WORKDIR /build/client                           │   │
│  │ 2. COPY client/package*.json ./                    │   │
│  │ 3. RUN npm ci                                      │   │
│  │ 4. COPY client/src ./src                           │   │
│  │ 5. COPY client/public ./public                     │   │
│  │ 6. RUN npm run build                               │   │
│  │                                                    │   │
│  │ Output: /build/client/dist → React app (static)   │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Stage 2: SERVER BUILDER                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Base Image: node:20-alpine                         │   │
│  │ 1. WORKDIR /build/server                           │   │
│  │ 2. COPY package*.json ./                           │   │
│  │ 3. RUN npm ci                                      │   │
│  │ 4. COPY server ./server                            │   │
│  │ 5. COPY config ./config                            │   │
│  │ 6. COPY scripts ./scripts                          │   │
│  │                                                    │   │
│  │ Output: /build/node_modules → dependencies         │   │
│  │         /build/server → Express app               │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Stage 3: RUNTIME                                          │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Base Image: node:20-alpine + nginx                 │   │
│  │ 1. COPY --from=client-builder /build/client/dist   │   │
│  │    → /app/client/dist                              │   │
│  │ 2. COPY --from=server-builder /build/node_modules  │   │
│  │    → /app/node_modules                             │   │
│  │ 3. COPY --from=server-builder /build/server        │   │
│  │    → /app/server                                   │   │
│  │ 4. COPY nginx.conf                                 │   │
│  │ 5. COPY docker-entrypoint.sh                       │   │
│  │ 6. ENTRYPOINT /app/scripts/entrypoint.sh           │   │
│  │                                                    │   │
│  │ Final Image: broadcast-system:latest (~500 MB)    │   │
│  │ • Only production artifacts                        │   │
│  │ • No build dependencies                            │   │
│  │ • Optimized for runtime                            │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Runtime Process Flow

```
┌───────────────────────────────────────────────────────────┐
│         Docker Container Startup (docker-entrypoint.sh)  │
├───────────────────────────────────────────────────────────┤
│                                                           │
│  1. Generate SSL Certificates                            │
│     ├─ Check if /etc/nginx/certs/server.crt exists       │
│     ├─ If not: openssl req -x509 ... (self-signed)       │
│     └─ Output: server.crt (365 day validity)             │
│                                                           │
│  2. Start Express Server                                 │
│     ├─ cd /app                                           │
│     ├─ node server/index.js &                            │
│     ├─ Wait for port 3001 to be ready                    │
│     └─ Background process (PID captured)                 │
│                                                           │
│  3. Configure Nginx                                      │
│     ├─ Load nginx.conf (main config)                     │
│     ├─ Load nginx-ssl.conf (routing & SSL)               │
│     ├─ Verify configuration: nginx -t                    │
│     └─ Check passes ✓                                    │
│                                                           │
│  4. Start Nginx (Foreground)                             │
│     ├─ nginx -g 'daemon off;'                            │
│     ├─ Listening on 80 (HTTP) and 443 (HTTPS)            │
│     └─ Log output to Docker logs                         │
│                                                           │
│  5. Health Check Ready                                   │
│     ├─ GET http://localhost/health → OK                  │
│     ├─ GET https://localhost/ → React app                │
│     ├─ GET https://localhost/api → Express server        │
│     └─ Status: HEALTHY ✓                                 │
│                                                           │
│  6. Trap Signals                                         │
│     ├─ SIGTERM/SIGINT captured                           │
│     ├─ Kill Express (pid $SERVER_PID)                    │
│     ├─ Kill Nginx (pid $NGINX_PID)                       │
│     └─ Graceful shutdown                                 │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

## Request Flow Through Nginx

```
HTTP Request (Port 80)
  │
  ├─ Regex match: Server block for :80
  │  └─ Condition: GET / on http://localhost
  │     └─ Action: return 301 https://$host$request_uri
  │        └─ Browser redirects to HTTPS (301 redirect)
  │
  ▼
HTTPS Request (Port 443)
  │
  ├─ SSL/TLS handshake
  │  ├─ Load certificate: /etc/nginx/certs/server.crt
  │  ├─ Load private key: /etc/nginx/certs/server.key
  │  └─ Negotiate protocol: TLSv1.2 / TLSv1.3
  │
  ├─ Request routing based on location block
  │
  ├─ IF path matches: /
  │  ├─ root /app/client/dist
  │  ├─ try_files $uri $uri/ /index.html
  │  ├─ Cache control set based on file type
  │  └─ Return: React app (SPA)
  │
  ├─ IF path matches: /api/
  │  ├─ rewrite ^/api/(.*)$ /$1 break
  │  ├─ proxy_pass http://broadcast_server
  │  ├─ Set proxy headers (X-Real-IP, X-Forwarded-*)
  │  ├─ Set WebSocket upgrade headers
  │  └─ Return: Express API response
  │
  ├─ IF path matches: /socket.io
  │  ├─ proxy_pass http://broadcast_server
  │  ├─ Set WebSocket upgrade headers (critical)
  │  ├─ No request buffering
  │  ├─ Long-lived connection
  │  └─ Return: WebSocket connection (persistent)
  │
  ├─ IF path matches: /health
  │  ├─ return 200 "healthy\n"
  │  ├─ Content-Type: text/plain
  │  └─ access_log off
  │
  ├─ Security headers applied to all responses:
  │  ├─ Strict-Transport-Security (HSTS)
  │  ├─ X-Frame-Options
  │  ├─ X-Content-Type-Options
  │  ├─ Access-Control-Allow-* headers
  │  └─ Referrer-Policy
  │
  └─ Compression (if enabled):
     ├─ Check if content-type in gzip_types list
     ├─ If yes: compress response
     ├─ Add: Content-Encoding: gzip
     └─ Return: Compressed response
```

## SSL/TLS Certificate Lifecycle

```
┌─────────────────────────────────────────────────────┐
│         SSL/TLS Certificate Generation Process      │
├─────────────────────────────────────────────────────┤
│                                                     │
│  Container Startup                                  │
│  │                                                  │
│  ├─ Check: /etc/nginx/certs/server.crt exists?     │
│  │                                                  │
│  ├─ IF exists:                                      │
│  │  └─ Log: "✅ SSL certificates found at $CERT_DIR" │
│  │     └─ Use existing certificates                 │
│  │        └─ Continue startup                       │
│  │                                                  │
│  ├─ IF NOT exists:                                  │
│  │  ├─ Log: "📜 Generating self-signed SSL certs..."│
│  │  ├─ mkdir -p /etc/nginx/certs                    │
│  │  ├─ openssl req -x509 -newkey rsa:4096 \         │
│  │  │   -keyout server.key \                        │
│  │  │   -out server.crt \                           │
│  │  │   -days 365 \                                 │
│  │  │   -nodes \                                    │
│  │  │   -subj "/C=US/ST=State/L=City/O=Org..."     │
│  │  ├─ chmod 600 server.key (read-only)            │
│  │  ├─ chmod 644 server.crt (readable)              │
│  │  ├─ Log: "✅ SSL certificates generated"         │
│  │  └─ Continue startup                             │
│  │                                                  │
│  └─ Nginx loads certificates:                       │
│     ├─ ssl_certificate /etc/nginx/certs/server.crt │
│     ├─ ssl_certificate_key /etc/nginx/certs/key    │
│     └─ Handshake ready ✓                            │
│                                                     │
└─────────────────────────────────────────────────────┘

Certificate Replacement (custom certs):
│
├─ Volume mount: ./broadcast-system/certs:/etc/nginx/certs
├─ Place files in broadcast-system/certs/:
│  ├─ server.crt (your certificate)
│  └─ server.key (your private key)
├─ Restart container
└─ Nginx reloads new certificates
```

## Health Check Flow

```
┌──────────────────────────────────────────────┐
│         Docker Health Check System           │
├──────────────────────────────────────────────┤
│                                              │
│  Every 30 seconds:                           │
│  1. Docker executes: curl -f http://localhost/health
│  2. Nginx receives request on port 80        │
│  3. location /health block matches           │
│  4. Return: 200 "healthy\n"                  │
│  5. Docker checks exit code (0 = success)    │
│  6. Update container health status           │
│                                              │
│  Health States:                              │
│  • starting (0-20s)      - Container started │
│  • healthy (20+s)        - Checks passing    │
│  • unhealthy (3 failures)- Checks failing    │
│                                              │
│  On failure:                                 │
│  • Docker logs warning                       │
│  • Service restart triggered (if configured) │
│  • docker-compose waits before depending svc │
│                                              │
└──────────────────────────────────────────────┘
```

## File Serving Logic

```
Client Request: GET /assets/app.123abc.js

    │
    ├─ Match location / block
    │
    ├─ root /app/client/dist
    │
    ├─ try_files $uri $uri/ /index.html
    │  └─ Try in order:
    │     1. /app/client/dist/assets/app.123abc.js (EXISTS ✓)
    │
    ├─ Check cache control rules:
    │  ├─ Matches location ~* \.(js|css|png|jpg|...
    │  ├─ Set headers:
    │  │  ├─ Cache-Control: public, immutable
    │  │  └─ Expires: 1 year in future
    │
    └─ Return file with cache headers

---

Client Request: GET /about

    │
    ├─ Match location / block
    │
    ├─ root /app/client/dist
    │
    ├─ try_files $uri $uri/ /index.html
    │  └─ Try in order:
    │     1. /app/client/dist/about (NOT FOUND)
    │     2. /app/client/dist/about/ (NOT FOUND)
    │     3. /app/client/dist/index.html (EXISTS ✓)
    │
    ├─ Check cache control rules:
    │  ├─ Matches location ~* \.html?$
    │  ├─ Set headers:
    │  │  ├─ Cache-Control: must-revalidate
    │  │  └─ Expires: expires -1 (no cache)
    │
    └─ Return index.html (SPA routing)
```

## WebSocket Connection Flow

```
Client Request: WS wss://localhost/socket.io?...

    │
    ├─ TLS handshake (HTTPS upgrade)
    │
    ├─ HTTP Upgrade request:
    │  ├─ Connection: upgrade
    │  ├─ Upgrade: websocket
    │  └─ Sec-WebSocket-Key: ...
    │
    ├─ Match location /socket.io block
    │
    ├─ Set proxy headers:
    │  ├─ Upgrade: $http_upgrade
    │  ├─ Connection: upgrade
    │  └─ X-Forwarded-* headers
    │
    ├─ proxy_pass http://broadcast_server
    │  └─ Forward to Express on port 3001
    │
    ├─ Express receives upgrade request
    │  ├─ Socket.io recognizes connection
    │  └─ Establishes persistent connection
    │
    ├─ Set timeouts for long-lived connection:
    │  ├─ proxy_connect_timeout: 7d
    │  ├─ proxy_send_timeout: 7d
    │  └─ proxy_read_timeout: 7d
    │
    ├─ HTTP 101 Switching Protocols
    │
    └─ Persistent WebSocket connection established
       ├─ Bidirectional communication
       ├─ Real-time updates
       └─ Connection maintained until client closes
```

---

**This architecture ensures:**
- ✅ Secure HTTPS communication
- ✅ Efficient static file serving
- ✅ Reliable API routing
- ✅ Real-time WebSocket support
- ✅ Automatic certificate management
- ✅ Health monitoring and recovery
