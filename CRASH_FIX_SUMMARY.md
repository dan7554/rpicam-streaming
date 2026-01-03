# MediaMTX Crash Fix - Quick Reference

## ✅ ISSUE RESOLVED

**Problem:** MediaMTX crashing on startup with error: `unexpected argument /mediamtx`  
**Root Cause:** ECS command overriding Docker ENTRYPOINT, causing argument duplication  
**Solution:** Pass only config file path to ECS command, let base image ENTRYPOINT handle binary  
**Status:** ✅ Fixed and deployed

---

## Current Deployment Status

```
Service:              mediamtx-service
Status:              ACTIVE
Running Tasks:       2/2
Task Definition:     mediamtx-task:15 ✅
Region:              us-east-1
Cluster:             broadcast-cluster

Command:             ["/app/mediamtx.yml"]  ← Only config file path
Image:               mediamtx:latest

All Listeners:       OPEN ✅
  - RTSP:  0.0.0.0:8554 (TCP)
  - RTMP:  0.0.0.0:1935
  - HLS:   0.0.0.0:8888
  - WebRTC: 0.0.0.0:8889
  - SRT:   0.0.0.0:8891 (UDP)
  - API:   0.0.0.0:8890
```

---

## Changes Made

### 1. Dockerfile
- **Removed:** Explicit `ENTRYPOINT ["/mediamtx", "/app/mediamtx.yml"]`
- **Reason:** Let base image ENTRYPOINT handle the binary

### 2. Makefile (Fargate - Line 184)
```makefile
# BEFORE:
"command": ["/mediamtx", "/app/mediamtx.yml"], \

# AFTER:
"command": ["/app/mediamtx.yml"], \
```

### 3. Makefile (EC2 - Line 331)
```makefile
# BEFORE:
\"command\": [\"/mediamtx\", \"/app/mediamtx.yml\"], \

# AFTER:
\"command\": [\"/app/mediamtx.yml\"], \
```

---

## Verification

### Service Status
```bash
aws ecs describe-services --cluster broadcast-cluster \
  --services mediamtx-service --region us-east-1
```

### Recent Logs
```bash
aws logs tail /ecs/mediamtx --region us-east-1 --since 10m
```

### Health Status
```bash
aws elbv2 describe-target-health \
  --target-group-arn <arn> --region us-east-1
```

---

## Stream Endpoints

Once verified with available streams via API:

- **RTSP:** `rtsp://broadcast-nlb-rtmp.elb.us-east-1.amazonaws.com:8554/rpicam2`
- **HLS:** `http://broadcast-nlb-rtmp.elb.us-east-1.amazonaws.com:8888/hls/rpicam2/index.m3u8`
- **RTMP:** `rtmp://broadcast-nlb-rtmp.elb.us-east-1.amazonaws.com:1935/rpicam2`
- **API Info:** `http://<task-ip>:8890/v3/info`
- **Streams List:** `http://<task-ip>:8890/v3/paths/list`

---

## Key Takeaway

**Docker ENTRYPOINT vs ECS Command:**
- Docker combines ENTRYPOINT + CMD: `/entrypoint arg1`
- ECS command **replaces** ENTRYPOINT: the cmd becomes the full process
- **Solution:** In ECS, only pass arguments, not the binary path

---

## RPi Stream Source

✅ **Status:** ACTIVE  
✅ **Process:** ffmpeg pushing to NLB:8554/rpicam2  
✅ **Confirmed:** 3 active ffmpeg processes on RPi  

Source: rpicam2 (IMX477 camera @ 1280x720@30fps H.264)

---

## Next Steps

1. ✅ Confirm MediaMTX not crashing → DONE
2. ⏳ Verify RPi stream is accessible via API list
3. ⏳ Test stream playback via HLS/RTSP/RTMP
4. ⏳ Run e2e-test-fargate.sh for full validation

---

**Documentation:** See `MEDIAMTX_CRASH_FIX.md` for detailed analysis  
**Deployment Date:** December 22, 2025  
**Task Definition:** revision 15
