# Changes Made - Quick Reference

## Summary
All RPi scripts and Makefile updated to reflect the debugged and working streaming configuration. Complete documentation added.

---

## Files Modified

### 1. **rpi/rpicam-stream.sh** ✅
**Changes:**
- Line 8: Changed `RTSP_SERVER_DOMAIN` from `rtsp.racetrackstreaming.com` → `13.59.160.208` (direct IP)
- Line 9: Changed `RTSP_SERVER_PORT` from `8554` → `1935` (RTMP port)
- Lines 39-55: Updated `check_rtsp_server()` to handle direct IPs without DNS lookup
- Lines 58-72: Changed FFmpeg output from `-f rtsp -rtsp_transport tcp` → `-f flv` (FLV for RTMP)
- Line 60: Changed URL protocol from `rtsp://` → `rtmp://`
- Lines 89-92: Updated log messages to say "RTMP" instead of "RTSP"

**Why:** Streaming now uses RTMP protocol to bypass CloudFlare proxy restrictions

---

### 2. **Makefile** ✅
**Changes Added:**
- Lines 72-79: New `build-cloud` target using `docker buildx --platform linux/amd64`
- Lines 81-85: New `build-rpi` target using `docker buildx --platform linux/arm64`
- Line 87: New `build-all` target to build for all platforms
- Lines 2202-2207: New `broadcast-build-cloud` target using BuildKit

**Why:** Proper cross-platform builds for deployment to ECS (AMD64) vs local development

---

### 3. **broadcast-system/Dockerfile** ✅
**Changes:**
- Line 1: Updated build instructions to recommend `docker buildx --platform linux/amd64`
- Lines 5-6: Removed `--platform=linux/amd64` FROM directives (let buildx handle it)
- Line 18: Changed npm install to be more robust: `npm install --no-save @rollup/rollup-linux-x64-musl || true`
- Line 29: Removed `--platform=linux/amd64` FROM directive

**Why:** Proper architecture handling with buildx instead of fixed platform flags

---

### 4. **broadcast-system/nginx-ssl.conf** ✅
Already updated previously with:
- WebRTC proxy to `/webrtc` → MediaMTX:8889
- API proxy to `/mediamtx/api/` → MediaMTX:9997
- Rate limiting zones configured
- WebSocket support enabled

---

### 5. **broadcast-system/config/cameras.json** ✅
Already updated previously with:
- Relative paths instead of hardcoded IPs
- Works with any domain now

---

### 6. **broadcast-system/server/services/CameraManager.js** ✅
Already updated previously with:
- Environment variable support for flexibility
- Proper MediaMTX API discovery

---

## New Files Added

### 1. **STREAMING_FIXES_SUMMARY.md** ✅
Comprehensive documentation including:
- All issues identified and how they were fixed
- Network architecture diagrams
- Deployment instructions
- Testing checklist
- Troubleshooting guide

### 2. **update-rpi-ip.sh** ✅
Automated script to:
- Query current MediaMTX ECS public IP
- SSH to rpicam2 and update configuration
- Restart streaming service
- Verify successful reconnection

Usage: `./update-rpi-ip.sh`

---

## Configuration Reference

### Current Streaming Setup (After Fixes)

**Protocol Chain:**
```
rpicam2 → RTMP (port 1935) → MediaMTX → WebRTC/HLS/RTSP → nginx → Browser
```

**Important IPs:**
- MediaMTX ECS Task: `13.59.160.208` (public IP, updates on redeployment)
- Broadcast Dashboard: `3.136.26.184` (accessible via https://admin.racetrackstreaming.com)
- rpicam2 Cellular: `174.162.192.174` (outbound connection)

**Key Ports:**
- RTMP Input: 1935 (rpicam2 → MediaMTX)
- WebRTC: 8889 (browser ← MediaMTX)
- HLS: 8888 (browser ← MediaMTX)
- RTSP: 8554 (optional, for other clients)
- API: 9997 (MediaMTX REST API)
- HTTPS: 443 (nginx dashboard)

---

## Build Commands

### For Local Development
```bash
# Build for your machine
make build

# Run with docker-compose
make broadcast-compose-up
```

### For Production Deployment
```bash
# Build and deploy MediaMTX to ECS
make ecs-deploy

# Build and deploy Broadcast to ECS
make broadcast-aws-quick-deploy

# Build for all platforms (local + cloud + RPi)
make build-all
```

### For Cross-Platform Testing
```bash
# Build AMD64 specifically
make build-cloud

# Build ARM64 for RPi
make build-rpi

# Build Broadcast for cloud
make broadcast-build-cloud
```

---

## Maintenance Procedures

### When MediaMTX ECS Task is Redeployed

The public IP will change. Update rpicam2:

**Option 1 (Automated):**
```bash
./update-rpi-ip.sh
```

**Option 2 (Manual):**
```bash
# Get new IP
NEW_IP=$(aws ecs describe-tasks --cluster mediamtx-cluster --tasks $(aws ecs list-tasks --cluster mediamtx-cluster --region us-east-2 --query 'taskArns[0]' --output text) --region us-east-2 --query 'tasks[0].attachments[?type==`ElasticNetworkInterface`].details[?name==`primaryPublicIpv4Address`].value' --output text)

# Update rpicam2
ssh dan7554@192.168.50.96 "sed -i 's/RTSP_SERVER_DOMAIN=\"[^\"]*\"/RTSP_SERVER_DOMAIN=\"$NEW_IP\"/g' /home/dan7554/rpicam-stream.sh && sudo systemctl restart rpicam-stream.service"
```

---

## Verification

### Check Streaming is Working

**From Local Machine:**
```bash
# Check MediaMTX is receiving stream
aws logs tail /ecs/mediamtx --follow=false | grep rpicam2

# Expected output:
# [path rpicam2] [recorder] recording 1 track (H264)
# [RTMP] [conn 174.162.192.174:52334] is publishing to path 'rpicam2'
```

### Check Dashboard is Working

```bash
# Open browser to:
https://admin.racetrackstreaming.com

# Should see:
# - Login page or dashboard
# - Camera list with rpicam2
# - Real-time video stream
# - WebRTC latency ~300-900ms
```

### Check nginx Proxies

```bash
# WebRTC proxy
curl -k https://admin.racetrackstreaming.com/webrtc/

# HLS proxy
curl -k https://admin.racetrackstreaming.com/hls/rpicam2/index.m3u8

# API proxy
curl -k https://admin.racetrackstreaming.com/mediamtx/api/v3/paths/list
```

---

## Git Commits

All changes tracked with commits:

```
1e8713c chore: Add automated script to update RPi when MediaMTX IP changes
379af95 docs: Add comprehensive streaming fixes documentation
4e0f657 fix: Update scripts and Makefile for proper RTMP streaming and platform-specific builds
```

---

## Completion Checklist

- [x] RPi script updated to RTMP protocol
- [x] Makefile updated with platform-specific builds
- [x] Broadcast Dockerfile fixed for cross-platform builds
- [x] nginx proxy configuration verified
- [x] Camera configuration updated
- [x] CameraManager environment support added
- [x] Documentation written (STREAMING_FIXES_SUMMARY.md)
- [x] Utility script created (update-rpi-ip.sh)
- [x] All changes committed to git
- [x] Streaming verified working end-to-end
- [x] Dashboard accessible and displaying stream
- [x] Rate limiting configured
- [x] API endpoints accessible

---

## Status

✅ **All systems operational**
- MediaMTX streaming from rpicam2
- Broadcast dashboard displaying video
- All proxies working correctly
- Platform-specific builds configured
- Documentation complete

