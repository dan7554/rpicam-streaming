# Subdomain Configuration Guide

**Last Updated:** December 13, 2025  
**Status:** ✅ Configured and Documented

---

## Overview

Your MediaMTX/Broadcast System uses **two subdomains** under `racetrackstreaming.com`:

| Subdomain | Purpose | Service | Routing |
|-----------|---------|---------|---------|
| **admin.racetrackstreaming.com** | Broadcast admin dashboard & control panel | Broadcast-System (Express.js + React) | `/` → static files, `/api/*` → backend |
| **stream.racetrackstreaming.com** | Live HLS/RTSP streams | MediaMTX | `/hls/*` → HLS streams, `/` → redirects |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Cloudflare DNS                                  │
│                                                                         │
│  admin.racetrackstreaming.com  → CNAME → ALB DNS                        │
│  stream.racetrackstreaming.com → CNAME → ALB DNS                        │
└──────────────┬──────────────────────────────────────────────────────────┘
               │
               ↓
    ┌──────────────────────────────┐
    │   AWS ALB (Port 80/443)       │
    │  broadcast-alb                │
    │                               │
    │ Both subdomains route to:     │
    │ Target Group: broadcast-      │
    │ targets (port 80)             │
    └──────────┬────────────────────┘
               │ (HTTP/HTTPS)
               ↓
    ┌──────────────────────────────────────────────┐
    │    ECS Container (Nginx + Express.js)         │
    │                                               │
    │    Nginx listens on port 80/443               │
    │    ├─ PORT 80: HTTP → HTTPS redirect          │
    │    └─ PORT 443: HTTPS with routing            │
    │                                               │
    │    Routing (all subdomains):                  │
    │    ├─ /health              → 200 OK           │
    │    ├─ /hls/*               → MediaMTX:8888    │
    │    ├─ /api/*  & /api/ws    → Express:3001     │
    │    └─ / (root)             → React frontend   │
    └──────────┬───────────────────────────────────┘
               │
    ┌──────────┴─────────────┐
    │                         │
    ↓                         ↓
(Internal Service DNS)  (Internal Service DNS)
mediamtx-service:8888   broadcast-server:3001
(MediaMTX HLS)          (Express.js Backend)
```

---

## DNS Configuration

### Required Cloudflare CNAME Records

Both subdomains must point to the same ALB DNS name. To set this up:

1. **Get ALB DNS name:**
   ```bash
   make dns-info
   ```
   Look for: `ALB DNS Name: broadcast-alb-xxx.us-east-1.elb.amazonaws.com`

2. **Add to Cloudflare (DNS settings):**

   **Record 1: Admin Dashboard**
   ```
   Type:    CNAME
   Name:    admin.racetrackstreaming.com
   Target:  broadcast-alb-xxx.us-east-1.elb.amazonaws.com
   TTL:     Auto
   Proxy:   ☑ Proxied (Cloudflare)  ← This enables SSL
   ```

   **Record 2: Streaming**
   ```
   Type:    CNAME
   Name:    stream.racetrackstreaming.com
   Target:  broadcast-alb-xxx.us-east-1.elb.amazonaws.com
   TTL:     Auto
   Proxy:   ☑ Proxied (Cloudflare)  ← This enables SSL
   ```

3. **Verify setup:**
   ```bash
   make dns-check
   ```

---

## Routing Details

### How the System Routes Requests

Since **both subdomains point to the same ALB**, Nginx differentiates based on **URL paths**, not hostnames:

#### Request: `https://admin.racetrackstreaming.com`
```
1. Browser → Cloudflare (SSL termination)
2. Cloudflare → ALB:443 (HTTPS)
3. ALB → Container:80 (HTTP)
4. Nginx checks path:
   - /health                      → Return 200 OK
   - /api/*, /api/ws              → Forward to Express.js:3001
   - /                            → Serve React static files
```

#### Request: `https://stream.racetrackstreaming.com/hls/rpicam2/index.m3u8`
```
1. Browser → Cloudflare (SSL termination)
2. Cloudflare → ALB:443 (HTTPS)
3. ALB → Container:80 (HTTP)
4. Nginx checks path:
   - /hls/rpicam2/index.m3u8      → Forward to MediaMTX:8888/rpicam2/index.m3u8
```

#### Request: `https://stream.racetrackstreaming.com/`
```
1. Browser → Cloudflare (SSL termination)
2. Cloudflare → ALB:443 (HTTPS)
3. ALB → Container:80 (HTTP)
4. Nginx checks path:
   - /                            → Serve React admin dashboard
```

---

## Use Cases

### Access Admin Dashboard
```bash
# Web browser
https://admin.racetrackstreaming.com

# Command line
curl https://admin.racetrackstreaming.com
curl https://admin.racetrackstreaming.com/health
curl https://admin.racetrackstreaming.com/api/health
```

### Stream Playback (HLS)
```bash
# HTTP client
curl https://stream.racetrackstreaming.com/hls/rpicam2/index.m3u8

# Video player (VLC, ffmpeg, etc.)
https://stream.racetrackstreaming.com/hls/rpicam2/

# Embedded in HTML
<video controls width="800">
  <source src="https://stream.racetrackstreaming.com/hls/rpicam2/index.m3u8" 
          type="application/x-mpegURL">
</video>
```

### Direct MediaMTX Access (Internal Only)
```bash
# From any service in ECS cluster
curl http://mediamtx-service.broadcast-cluster.ecs.local:8554/   # RTSP
curl http://mediamtx-service.broadcast-cluster.ecs.local:8888/   # HLS
```

---

## Configuration Files

### Makefile Variables
```makefile
# Location: Makefile (lines 65-72)
ADMIN_DOMAIN := admin.racetrackstreaming.com    # Broadcast admin dashboard
STREAM_DOMAIN := stream.racetrackstreaming.com   # MediaMTX HLS/RTSP streaming
DOMAIN := $(ADMIN_DOMAIN)                        # Default domain (backward compatibility)
```

### Nginx Routing (broadcast-system/nginx-ssl.conf)
```nginx
# Lines 1-12: Upstream services
upstream mediamtx_server {
    server mediamtx-service.broadcast-cluster.ecs.local:8888;
}
upstream broadcast_server {
    server localhost:3001;
}

# Lines 94-108: HLS routing
location /hls/ {
    proxy_pass http://mediamtx_server/;
}

# Lines 110-122: WebSocket routing
location /api/ws {
    proxy_pass http://broadcast_server;
}

# Lines 124-131: API routing
location /api/ {
    proxy_pass http://broadcast_server;
}

# Lines 133-140: Static files (admin dashboard)
location / {
    try_files $uri $uri/ /index.html;
    root /app/client/dist;
}
```

### ECS Task Definition (Makefile, broadcast-task-def)
```json
{
  "environment": [
    { "name": "NODE_ENV", "value": "production" },
    { "name": "PORT", "value": "3001" },
    { "name": "BROADCAST_HOSTNAME", "value": "admin.racetrackstreaming.com" },
    { "name": "MEDIAMTX_URL", "value": "http://mediamtx-service.broadcast-cluster.ecs.local:8889" }
  ]
}
```

---

## Testing & Verification

### 1. Check DNS Resolution
```bash
# Should resolve to ALB IP
dig admin.racetrackstreaming.com
dig stream.racetrackstreaming.com

# Both should point to same ALB
nslookup admin.racetrackstreaming.com
nslookup stream.racetrackstreaming.com
```

### 2. Test Health Endpoints
```bash
# Admin dashboard
curl -v https://admin.racetrackstreaming.com/health
curl -v https://admin.racetrackstreaming.com/api/health

# Streaming (should have /hls/ in path)
curl -v https://stream.racetrackstreaming.com/hls/rpicam2/index.m3u8
```

### 3. Test Streaming
```bash
# Get stream list
curl https://stream.racetrackstreaming.com/hls/

# Play HLS in VLC
vlc https://stream.racetrackstreaming.com/hls/rpicam2/

# Play HLS with ffplay
ffplay https://stream.racetrackstreaming.com/hls/rpicam2/index.m3u8
```

### 4. Makefile Commands
```bash
# Show configuration
make dns-info          # Shows both subdomains and required CNAME records
make dns-check         # Tests accessibility of both subdomains
make debug-env         # Shows all Makefile variables including domains
```

---

## Troubleshooting

### Both Domains Show Same Content
**Expected Behavior** ✅ - This is correct! Both subdomains route to the same container, which serves different content based on URL paths:
- `admin.*` + `/` → Dashboard
- `stream.*` + `/hls/` → Streams

### Streams Not Loading via `stream.racetrackstreaming.com`
**Check:**
1. Nginx routing: `/hls/*` → MediaMTX upstream
2. MediaMTX upstream accessible: `mediamtx-service.broadcast-cluster.ecs.local:8888`
3. Logs: `make logs`

**Fix:**
```bash
# Restart services
make deploy

# Check logs for nginx errors
aws logs tail /ecs/broadcast --follow
```

### DNS Not Resolving
**Check:**
1. Cloudflare DNS records configured: `make dns-info`
2. Cloudflare SSL mode: Should be "Full" or "Full (Strict)"
3. TTL: May need to wait for cache expiration

**Verify:**
```bash
# Check Cloudflare records
dig admin.racetrackstreaming.com @1.1.1.1  # Cloudflare nameserver
dig stream.racetrackstreaming.com @1.1.1.1

# Check propagation
nslookup -type=CNAME admin.racetrackstreaming.com
```

### SSL Certificate Issues
**Issue:** Certificate shows only `admin.racetrackstreaming.com`

**Reason:** Both subdomains use same certificate (in ALB listener)

**Fix:** When requesting ACM certificate, include both subdomains:
```bash
aws acm request-certificate \
  --domain-name admin.racetrackstreaming.com \
  --subject-alternative-names stream.racetrackstreaming.com \
  --validation-method DNS
```

---

## Future Enhancements

### Option 1: Separate ALBs (Not Recommended)
If you wanted separate infrastructure:
- `admin.racetrackstreaming.com` → ALB1 → Broadcast container
- `stream.racetrackstreaming.com` → ALB2 → MediaMTX direct

**Pros:** Cleaner separation, can scale independently  
**Cons:** Double cost, complex DNS, redundant

### Option 2: Path-Based Routing (Current ✅)
What you have now - works great!
- Same ALB, same container
- Single DNS entry per subdomain
- Cost-efficient
- Nginx handles routing

### Option 3: Subdomain-Aware Nginx (Future)
If you want Nginx to respond differently based on hostname:
```nginx
server {
    server_name stream.racetrackstreaming.com;
    # Only serve /hls/ paths
}

server {
    server_name admin.racetrackstreaming.com;
    # Only serve admin dashboard
}
```

---

## Summary

✅ **Current Setup:**
- Both subdomains use same ALB and container
- Nginx routes based on URL paths
- Cost-efficient and easy to manage
- Proper SSL/TLS through Cloudflare
- Clear separation of concerns

✅ **What's Configured:**
- Makefile variables for both domains
- Nginx upstream servers
- ECS service discovery for internal routing
- Cloudflare SSL proxy

✅ **How to Verify:**
```bash
make dns-info     # Show configuration
make dns-check    # Test accessibility
make status       # Show deployment status
```

---

**Need to make changes?**
1. Update `ADMIN_DOMAIN` or `STREAM_DOMAIN` in Makefile
2. Update Cloudflare CNAME records
3. Redeploy: `make deploy`

