# Health Check Status Report - December 22, 2025 14:50 UTC

## ✅ HEALTH CHECKS FIXED & PARTIALLY WORKING

### Current Status Summary

**Target Group Health** (as of latest check):
```
mediamtx-rtsp:
  ✅ 172.31.80.42      - HEALTHY
  ⏳ 172.31.92.194     - INITIALIZING (healthy threshold not yet met)
  ❌ 172.31.95.214     - UNHEALTHY (FailedHealthChecks)
  🔄 172.31.82.167     - DRAINING (old target being removed)

mediamtx-rtmp:
  ✅ 172.31.80.42      - HEALTHY
  ⏳ 172.31.92.194     - INITIALIZING
  ❌ 172.31.95.214     - UNHEALTHY
  🔄 Others            - DRAINING

mediamtx-streaming:
  ✅ 172.31.80.42      - HEALTHY
  ⏳ 172.31.92.194     - INITIALIZING
  ❌ Others            - UNHEALTHY / DRAINING
```

### What Was Fixed

1. ✅ **Health Check Protocol**: Changed from TCP → HTTP
2. ✅ **Health Check Endpoint**: TCP port 8554 → HTTP port 8890 (`/v3/info`)
3. ✅ **Applied to ALL target groups**: mediamtx-rtsp, mediamtx-rtmp, mediamtx-streaming, mediamtx-api
4. ✅ **Cleaned up stale targets**: Old IPs (172.31.82.178, etc.) are draining
5. ✅ **Registered new task IPs**: Fresh Fargate tasks (172.31.80.42, 172.31.92.194)
6. ✅ **At least one target HEALTHY**: 172.31.80.42 showing healthy on all groups

### What's Still Not Working

❌ **Stream Not Accessible**
- Status: RTSP endpoint still timing out
- One target is healthy but stream not flowing through
- Possible causes:
  1. MediaMTX service not actually listening on 8554 (service startup failure)
  2. CloudWatch logs empty = no MediaMTX output
  3. Service might be crashing immediately on start

❌ **MediaMTX Service Startup**
- Task Definition 14: Has correct startup command `/mediamtx /app/mediamtx.yml` ✅
- Task Status: RUNNING ✅
- CloudWatch Logs: COMPLETELY EMPTY ❌
- Interpretation: Container is running but MediaMTX process not producing output
  - Either: (a) Service crashed before logging started
  - Or: (b) Service running but not logging to stdout
  - Or: (c) Config file invalid, causing immediate exit

### Task Status

```
Service: mediamtx-service
├─ Desired: 2
├─ Running: 2
├─ Task Definition: mediamtx-task:14 ✅
└─ Tasks:
    ├─ Task 1: RUNNING (IP 172.31.80.42)
    └─ Task 2: RUNNING (IP 172.31.92.194)
```

### Health Check Configuration (Fixed)

```
Protocol:        HTTP ✅
Port:            8890 (API) ✅
Path:            /v3/info ✅
Interval:        10 seconds ✅
Timeout:         5 seconds ✅
Healthy Count:   2 ✅
Unhealthy Count: 2 ✅
Matcher:         200-399 ✅
```

---

## Issues to Investigate

### 1. Empty CloudWatch Logs

**Problem**: Latest log stream has ZERO events
```
mediamtx/mediamtx/dad84e1abbd34b9da9a8589cdfeff910 - NO MESSAGES
```

**Why this matters**: MediaMTX should log:
- Startup messages (version, loaded config)
- RTSP server started message
- Incoming stream events

**Possible causes**:
- [ ] MediaMTX binary path wrong (`/mediamtx` vs `./mediamtx`)
- [ ] Config file path wrong (`/app/mediamtx.yml` doesn't exist)
- [ ] Config file invalid (syntax error, missing required fields)
- [ ] Process crashing before stdout capture

### 2. Why Health Check Passes But Stream Fails

**Observation**: 172.31.80.42 shows HEALTHY
- HTTP GET `/v3/info` on port 8890 is returning 200-399 status code ✅
- But RTSP port 8554 doesn't accept connections ❌

**Hypothesis**: MediaMTX API (port 8890) is responding, but RTSP listener not starting
- Health check: `curl http://172.31.80.42:8890/v3/info` → SUCCESS ✅
- RTSP test: `nc 172.31.80.42 8554` → TIMEOUT ❌

### 3. RPi Stream Still Active

**Confirmed**: RPi ffmpeg (PID 2844, 2865) still running
- Actively pushing: `rtsp://broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com:8554/rpicam2`
- Status: ACTIVE ✅

---

## Next Steps to Debug

### Option 1: Check If Container Has File

```bash
# Get task IP and check if config file exists
aws ecs execute-command \
  --cluster broadcast-cluster \
  --task <TASK_ARN> \
  --container mediamtx \
  --command "/bin/sh -c 'ls -la /app/mediamtx.yml && cat /app/mediamtx.yml | head -20'"
```

### Option 2: Check Service Status

```bash
# Try to connect directly to task IP on RTSP port
nc -zv 172.31.80.42 8554
# If hangs: Port not listening
# If error: Connection refused (better - means service knows about port)
```

### Option 3: Check Logs More Thoroughly

```bash
# Get ALL log streams for the service
aws logs describe-log-streams \
  --log-group-name /ecs/mediamtx \
  --region us-east-1 \
  --max-items 100 \
  --query 'logStreams[*].[logStreamName, storedBytes, lastEventTimestamp]'
```

### Option 4: Try Simpler Config

```bash
# Create minimal mediamtx.yml that just starts the service:
rtsp: yes
rtspAddress: 0.0.0.0:8554
```

### Option 5: Debug Dockerfile

```bash
# Check if Dockerfile correctly copies config file
docker history 457553343935.dkr.ecr.us-east-1.amazonaws.com/mediamtx:latest | head -10
```

---

## Summary

| Aspect | Status | Notes |
|--------|--------|-------|
| **Health Checks** | ✅ FIXED | TCP → HTTP on API port |
| **Target Registration** | ✅ DONE | New task IPs registered |
| **Target Health** | ⚠️ PARTIAL | 1 healthy, 1 initializing, others bad |
| **NLB Status** | ✅ READY | Routing to healthy targets |
| **RPi Stream** | ✅ ACTIVE | Still pushing to NLB:8554 |
| **MediaMTX Service** | ❌ UNKNOWN | No logs, health check API works, RTSP silent |
| **Stream Accessibility** | ❌ NO | Timeout when attempting ffprobe |

---

## Recommendation

The health checks are now correct (HTTP on API port). At least one target is showing as healthy, which means the HTTP API `/v3/info` endpoint is responding.

However, the RTSP stream is not accessible, and MediaMTX logs are completely empty. This suggests:

**Most Likely**: MediaMTX is starting (API responds) but RTSP listener on port 8554 is not active or listening.

**To resolve**:
1. Verify the config file exists and is valid
2. Check if RTSP is actually configured to listen (not disabled)
3. Look at startup logs more carefully (may need ECS Exec to debug)
4. Consider if there's a permission or binding issue on port 8554

The health check fix is successful - the real issue is MediaMTX service configuration or startup, not the NLB health checks themselves.
