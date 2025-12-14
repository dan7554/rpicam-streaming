# Quick Reference: Subdomain Configuration

## The Setup

| Subdomain | Purpose | Access |
|-----------|---------|--------|
| **admin.racetrackstreaming.com** | Admin Dashboard | Dashboard UI, API, WebSocket |
| **stream.racetrackstreaming.com** | Live Streams | HLS/RTSP video feeds |

## Key Points

✅ Both point to **same ALB** → Same container → Nginx routes based on **path**

## DNS Requirements (Cloudflare)

```
admin.racetrackstreaming.com  → CNAME → broadcast-alb-xxx.us-east-1.elb.amazonaws.com
stream.racetrackstreaming.com → CNAME → broadcast-alb-xxx.us-east-1.elb.amazonaws.com
```

Get ALB DNS:
```bash
make dns-info
```

## Routing

```
admin.racetrackstreaming.com
  ├─ /              → React Dashboard
  ├─ /api/*         → Express.js Backend
  └─ /api/ws        → WebSocket Control

stream.racetrackstreaming.com
  ├─ /hls/*         → MediaMTX Streams
  ├─ /api/*         → Express.js Metadata
  └─ /              → React Dashboard (fallback)
```

## Nginx Upstream Servers

```nginx
upstream mediamtx_server {
    server mediamtx-service.broadcast-cluster.ecs.local:8888;
}
upstream broadcast_server {
    server localhost:3001;  # Express.js
}
```

## Common Commands

```bash
# Show configuration
make dns-info          # Show DNS requirements
make debug-env         # Show all variables
make status            # Show deployment status

# Test connectivity
make dns-check         # Test both domains

# Deploy
make deploy            # Deploy latest versions
make quick             # Quick update (broadcast-system only)
```

## Access URLs

```
Admin Dashboard:     https://admin.racetrackstreaming.com
Stream Playback:     https://stream.racetrackstreaming.com/hls/<stream>/
Health Check (Admin): https://admin.racetrackstreaming.com/health
Health Check (Stream): https://stream.racetrackstreaming.com/health
```

## File Locations

```
Makefile Variables:        Makefile (lines 65-72)
Nginx Routing:             broadcast-system/nginx-ssl.conf (lines 1-140)
Docker Entrypoint:         broadcast-system/docker-entrypoint.sh
Detailed Documentation:    SUBDOMAIN_CONFIGURATION.md
Setup Verification:        SUBDOMAIN_SETUP_VERIFICATION.md
```

## Troubleshooting

| Problem | Check |
|---------|-------|
| Both domains show same content | ✓ Expected! Path-based routing |
| DNS doesn't resolve | Cloudflare CNAME records set? |
| Streams not loading | `/hls/` proxy to mediamtx-server working? |
| SSL certificate error | Both domains on same cert? |

## Modification Template

Change domains in Makefile:
```makefile
ADMIN_DOMAIN := admin.racetrackstreaming.com
STREAM_DOMAIN := stream.racetrackstreaming.com
```

Then:
```bash
make dns-info      # Verify new configuration
make deploy        # Redeploy
```

---

**Everything is configured! ✅**

Run: `make dns-info` to see your setup
Run: `make dns-check` to test both domains
