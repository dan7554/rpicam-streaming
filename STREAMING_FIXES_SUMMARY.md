# Streaming System Fixes - Complete Summary

## Date: December 7, 2025
## Status: ✅ All Critical Issues Resolved

---

## Executive Summary

Successfully debugged and fixed the complete broadcast streaming pipeline. The system now:
- ✅ rpicam2 streams H264 video via RTMP to MediaMTX
- ✅ MediaMTX multiplexes to WebRTC, HLS, and RTSP
- ✅ Broadcast dashboard displays real-time video (~300-900ms latency)
- ✅ All services running on AWS ECS and Raspberry Pi

---

## Issues Fixed

### 1. MediaMTX ECS Task Failing to Start

**Problem:**
- ECS task deployment failing with: `ERR: json: unknown field "webUI"`
- Task definition had invalid configuration

**Root Cause:**
- `webUI` field doesn't exist in MediaMTX v1.15.5
- Field was added incorrectly during earlier debugging

**Solution:**
- Removed `webUI: yes` and `webUIAddress: :9997` from `mediamtx-container.yml`
- MediaMTX exposes its REST API on port 9997 (no separate web UI needed)

**File Modified:** `mediamtx-container.yml`

**Result:** ✅ MediaMTX ECS task now running successfully

---

### 2. rpicam2 Streaming Not Working

**Problems:**
- Script using wrong protocol (RTSP instead of RTMP)
- Script using wrong port (8554 instead of 1935)
- DNS resolving to CloudFlare CDN IPs (CloudFlare blocks RTMP/RTSP)
- ffmpeg process never started

**Root Causes:**
1. **Protocol Mismatch:** Script configured for RTSP but MediaMTX expects RTMP
2. **Port Mismatch:** RTSP on port 8554, but RTMP uses 1935
3. **DNS Issue:** `rtsp.racetrackstreaming.com` proxied through CloudFlare
   - CloudFlare IPs: `104.21.51.113`, `172.67.179.130`
   - These IPs don't support RTMP/RTSP protocols

**Solutions Applied:**

1. **Update Protocol Configuration (rpi/rpicam-stream.sh):**
   - Changed `RTSP_SERVER_PORT` from `8554` → `1935`
   - Changed URL from `rtsp://` → `rtmp://`
   - Changed FFmpeg output from `-f rtsp -rtsp_transport tcp` → `-f flv`

2. **Bypass CloudFlare DNS:**
   - Changed `RTSP_SERVER_DOMAIN` from `rtsp.racetrackstreaming.com` → `13.59.160.208`
   - Uses direct public IP of MediaMTX ECS task
   - Bypasses CloudFlare proxy entirely

3. **Improved Connectivity Logic:**
   - Added IP detection to handle both hostnames and direct IPs
   - Prevents unnecessary DNS lookups when direct IP provided

**Files Modified:**
- `rpi/rpicam-stream.sh` - Complete protocol update

**Result:** ✅ rpicam2 now streams H264 via RTMP to MediaMTX successfully

---

### 3. Broadcast System Not Deploying

**Problem:**
- ECS task failing: `CannotPullContainerError: image not found`
- Runtime error: `exec /app/scripts/entrypoint.sh: exec format error`

**Root Causes:**
1. Broadcast image not pushed to ECR
2. Docker image built on ARM64 Mac, ECS expecting AMD64

**Solutions Applied:**

1. **Build for Correct Architecture:**
   - Built with `--platform linux/amd64` flag
   - Used BuildKit for proper cross-platform compilation

2. **Push to ECR:**
   - Created ECR repository: `broadcast-system`
   - Pushed AMD64 image with proper tagging

3. **Update ECS Service:**
   - Forced new deployment with new image
   - Task now runs successfully

**Result:** ✅ Broadcast service running on ECS

---

## Build System Updates

### Makefile Improvements

**New Platform-Specific Build Targets:**

```bash
# Build for local machine (native architecture)
make build

# Build for AWS ECS deployment (AMD64)
make build-cloud
make broadcast-build-cloud

# Build for Raspberry Pi (ARM64)
make build-rpi

# Build for all platforms
make build-all
```

**Key Changes:**
- Added `DOCKER_BUILDKIT=1` for proper cross-platform builds
- Switched from `docker build` to `docker buildx` for better platform support
- Added `--platform` flags for explicit architecture targeting

**Files Modified:** `Makefile`

---

## Configuration Changes

### RPi Streaming Configuration

**File:** `rpi/rpicam-stream.sh`

```bash
# OLD (broken)
RTSP_SERVER_DOMAIN="rtsp.racetrackstreaming.com"
RTSP_SERVER_PORT="8554"
ffmpeg ... -f rtsp -rtsp_transport tcp ...

# NEW (working)
RTSP_SERVER_DOMAIN="13.59.160.208"  # Direct MediaMTX IP
RTSP_SERVER_PORT="1935"             # RTMP port
ffmpeg ... -f flv ...                # FLV for RTMP
```

**Updates to MediaMTX IP:**
When MediaMTX ECS task is redeployed, update the IP using:

```bash
aws ecs describe-tasks \
  --cluster mediamtx-cluster \
  --tasks $(aws ecs list-tasks --cluster mediamtx-cluster --region us-east-2 --query 'taskArns[0]' --output text) \
  --region us-east-2 \
  --query 'tasks[0].attachments[?type==`ElasticNetworkInterface`].details[?name==`primaryPublicIpv4Address`].value' \
  --output text
```

### nginx Proxy Configuration

**File:** `broadcast-system/nginx-ssl.conf`

**New Endpoints:**
- `/webrtc` → MediaMTX WebRTC on port 8889
- `/hls/` → MediaMTX HLS on port 8888
- `/mediamtx/api/` → MediaMTX REST API on port 9997

**New Features:**
- Rate limiting zones (general: 20r/s, api: 100r/s, streaming: 50r/s)
- Proper WebSocket support
- Updated CSP headers for web UI resources

### Camera Configuration

**File:** `broadcast-system/config/cameras.json`

**Change:** Relative paths instead of hardcoded IPs
```json
// OLD
{ "url": "http://172.31.19.132:8889/webrtc?path=rpicam2" }

// NEW (works with any domain)
{ "url": "/webrtc?path=rpicam2" }
```

### Docker Configuration

**File:** `broadcast-system/Dockerfile`

**Changes:**
- Removed problematic `--platform=linux/amd64` FROM flags
- Let `docker buildx` handle platform-specific configuration
- Fixed npm dependencies for target platform
- Improved rollup bindings installation

---

## Network Architecture (Final State)

```
┌─────────────────────────────────────────────────────────────┐
│                        Internet                              │
│  Cellular Modem (174.162.192.174) ← rpicam2 Stream         │
└─────────────────────────────────────────────────────────────┘
                            ↓
                    (RTMP on port 1935)
                            ↓
┌─────────────────────────────────────────────────────────────┐
│                  AWS ECS (us-east-2)                        │
│  MediaMTX (13.59.160.208:1935)                             │
│  ├─→ Receives: RTMP on 1935                                │
│  ├─→ Outputs: WebRTC on 8889                               │
│  ├─→ Outputs: HLS on 8888                                  │
│  ├─→ Outputs: RTSP on 8554                                 │
│  └─→ API on 9997                                           │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│            Broadcast Service (3.136.26.184)                │
│  nginx + Express.js                                         │
│  ├─→ Proxy: /webrtc → MediaMTX:8889 (WebRTC)              │
│  ├─→ Proxy: /hls/ → MediaMTX:8888 (HLS)                   │
│  ├─→ Proxy: /mediamtx/api/ → MediaMTX:9997 (API)          │
│  ├─→ SPA: / → React Dashboard                             │
│  └─→ API: /api → Express.js Backend                       │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│                    Browser / Client                         │
│  https://admin.racetrackstreaming.com                      │
│  ├─→ Dashboard View                                         │
│  ├─→ WebRTC Stream (300-900ms latency)                     │
│  ├─→ Camera Controls                                        │
│  └─→ Commentary System                                      │
└─────────────────────────────────────────────────────────────┘
```

---

## Verified Functionality

### ✅ MediaMTX Service
- Listening on RTMP (1935), RTSP (8554), HLS (8888), WebRTC (8889)
- Receiving H264 stream from rpicam2
- Log: `[path rpicam2] [recorder] recording 1 track (H264)`

### ✅ Camera Streaming
- rpicam2 connected and streaming
- Connection: `174.162.192.174:52334` → `13.59.160.208:1935`
- Status: Publishing RTMP with H264 codec

### ✅ Broadcast Dashboard
- Service: Running on ECS
- Accessible: https://admin.racetrackstreaming.com
- Features: Real-time camera view, commentary, scene management

### ✅ nginx Proxying
- WebRTC proxy: `/webrtc` → working
- HLS proxy: `/hls/` → working
- API proxy: `/mediamtx/api/v3/` → working
- Rate limiting: Active on all endpoints

---

## Deployment Instructions

### For Development (Local Testing)

```bash
# Build for your machine
make build

# Build for all platforms
make build-all

# Run locally with docker-compose
make broadcast-compose-up
```

### For Production (AWS ECS)

```bash
# Deploy MediaMTX
make ecs-deploy

# Deploy Broadcast System
make broadcast-aws-quick-deploy

# Update DNS records
make broadcast-aws-update-dns
```

### Update MediaMTX IP in RPi Script

After redeploying MediaMTX ECS task, update the IP in rpicam2:

```bash
# Get new IP
NEW_IP=$(aws ecs describe-tasks --cluster mediamtx-cluster --tasks $(aws ecs list-tasks --cluster mediamtx-cluster --region us-east-2 --query 'taskArns[0]' --output text) --region us-east-2 --query 'tasks[0].attachments[?type==`ElasticNetworkInterface`].details[?name==`primaryPublicIpv4Address`].value' --output text)

# SSH to Pi and update
ssh dan7554@192.168.50.96 "sed -i 's/RTSP_SERVER_DOMAIN=\"[^\"]*\"/RTSP_SERVER_DOMAIN=\"$NEW_IP\"/g' /home/dan7554/rpicam-stream.sh && sudo systemctl restart rpicam-stream.service"
```

---

## Known Limitations & Workarounds

### CloudFlare DNS Proxy
- **Issue:** CloudFlare doesn't support RTMP/RTSP protocols
- **Workaround:** Use direct IP address instead of domain name
- **Resolution:** Change DNS record from CloudFlare proxy (orange ☁️) to DNS-only (gray ☁️)

### ECS Task IP Changes
- **Issue:** ECS tasks get new IPs on redeployment
- **Workaround:** Update rpicam-stream.sh manually
- **Long-term:** Consider Tailscale integration or service discovery

### Architecture Consistency
- **Issue:** Docker images must be built for target platform
- **Solution:** Use docker buildx with `--platform` for cross-compilation

---

## Commit History

All changes committed with:
```
commit: fix: Update scripts and Makefile for proper RTMP streaming and platform-specific builds
```

Changes include:
- rpicam-stream.sh: RTMP protocol update
- Makefile: Platform-specific build targets
- Broadcast Dockerfile: Platform configuration fixes
- nginx-ssl.conf: WebRTC/API proxy configuration
- CameraManager.js: Environment variable support
- cameras.json: Relative path configuration

---

## Testing Checklist

- [x] MediaMTX ECS task deploys successfully
- [x] rpicam2 connects and streams RTMP
- [x] MediaMTX receives and records stream
- [x] Broadcast service deploys successfully
- [x] nginx proxies WebRTC stream correctly
- [x] Dashboard displays camera stream
- [x] WebRTC latency < 1 second
- [x] Rate limiting works
- [x] API endpoints accessible
- [x] Platform-specific builds work (AMD64, ARM64)

---

## Next Steps

1. **Monitor Production**
   - Watch MediaMTX logs for streaming health
   - Monitor ECS task health checks
   - Track WebRTC connection statistics

2. **Optional Enhancements**
   - Implement Tailscale for RPi-to-ECS direct connection
   - Add automatic IP update mechanism
   - Enable video recording to S3
   - Implement multi-camera support

3. **Documentation**
   - Update user guides with new commands
   - Document troubleshooting procedures
   - Create operational runbooks

---

## Contact & Support

For issues or questions about the streaming system:
- Check logs: `aws logs tail /ecs/mediamtx`, `/ecs/broadcast`
- Monitor streaming: SSH to rpicam2 and check `systemctl status rpicam-stream.service`
- Test connectivity: `nc -zv -w 3 13.59.160.208 1935`

