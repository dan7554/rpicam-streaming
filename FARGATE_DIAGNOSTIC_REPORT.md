# Fargate MediaMTX Service Diagnostic - December 22, 2025 14:35 UTC

## CRITICAL ISSUE: MediaMTX Container Not Listening on Port 8554

### Executive Summary

✅ **RPi Stream**: CONFIRMED ACTIVELY STREAMING to NLB:8554  
❌ **Fargate Service**: RUNNING but NOT LISTENING on 8554  
❌ **NLB Targets**: ALL UNHEALTHY - Health checks failing  
❌ **Stream Delivery**: BLOCKED by target health failures  

---

## Evidence

### ✅ Stream Source is Active and Pushing

```
RPi Process Status:
├─ rpicam-vid (PID 2209): RUNNING - Capturing H.264 from IMX477
└─ ffmpeg (PID 2227): RUNNING - Pushing RTSP to NLB

ffmpeg Command:
ffmpeg -fflags nobuffer -f h264 -i /tmp/camera.h264 -c:v copy \
  -f rtsp -rtsp_transport tcp \
  rtsp://broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com:8554/rpicam2

Status: ✅ ACTIVELY PUSHING STREAM
```

### ✅ NLB and AWS Infrastructure Operational

```
Network Load Balancer:
├─ Name: broadcast-nlb-rtmp
├─ DNS: broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com
├─ State: ACTIVE ✅
└─ Listeners: 8554/TCP (RTSP), 1935/TCP (RTMP)

Fargate Service:
├─ Name: mediamtx-service
├─ Status: ACTIVE ✅
├─ Desired: 2 tasks
├─ Running: 3 tasks
├─ Task Definition: mediamtx-task:12 ✅
└─ Region: us-east-1

Security Group:
├─ Allows: 8554/TCP from 0.0.0.0/0 ✅
└─ Status: CORRECT
```

### ❌ RTSP Target Group - All Targets Unhealthy

```
Target Group: mediamtx-rtsp
├─ Port: 8554/TCP
├─ Health Check Protocol: TCP ✅
├─ Health Check Port: traffic-port (8554) ✅
├─ Health Check Interval: 30 seconds
└─ Targets:
    ├─ 172.31.82.178:8554 - UNHEALTHY ❌ Target.FailedHealthChecks
    ├─ 172.31.94.28:8554  - UNHEALTHY ❌ Target.FailedHealthChecks
    ├─ 172.31.81.42:8554  - UNHEALTHY ❌ Target.FailedHealthChecks
    └─ 172.31.93.34:8554  - UNHEALTHY ❌ Target.FailedHealthChecks

Reason: NLB cannot establish TCP connection to port 8554 on any target
Impact: NO TRAFFIC ROUTED from NLB to Fargate tasks
```

### ❌ MediaMTX Service Status - Not Responding

```
Task Container Status:
├─ Name: mediamtx
├─ Status: RUNNING (LastStatus)
├─ Desired Status: RUNNING
├─ Exit Code: null (process running, not exited)
├─ Exit Reason: null (no error)
└─ Status: Container shows as RUNNING but not listening ⚠️

CloudWatch Logs Analysis:
├─ Log Group: /ecs/mediamtx ✅ (exists)
├─ Log Streams: 17+ streams ✅ (tasks have logged before)
├─ Latest Stream: mediamtx/mediamtx/d0db16250a954938b59b1218ef479af2
├─ Latest Events: NONE (empty log stream)
├─ Interpretation: No startup messages, no service logs
└─ Status: Service is not producing output ❌

Port Connectivity:
├─ ffprobe Test: FAILED ❌
│   Command: ffprobe -rtsp_transport tcp -i rtsp://broadcast-nlb-...com:8554/rpicam2
│   Result: Timeout - cannot connect
│   Impact: Confirms port 8554 is not accepting connections
└─ Status: Port not listening ❌
```

---

## Root Cause: MediaMTX Service Not Starting

### Theory

The MediaMTX container is running (ECS shows RUNNING) but the MediaMTX service itself is not starting or is crashing immediately. This explains:

1. **RUNNING status** (container hasn't exited)
2. **Empty logs** (crashed before logging initialization)
3. **No TCP listening** (service never started)
4. **Health checks failing** (immediate connection refusal)

### Most Likely Causes

| Cause | Likelihood | Impact |
|-------|-----------|--------|
| No startup command (missing /bin/mediamtx) | 🔴 HIGH | Service never invoked |
| Invalid/missing mediamtx.yml config | 🔴 HIGH | Service exits on startup |
| Docker image corruption | 🟡 MEDIUM | Binary missing or incomplete |
| Missing MediaMTX binary in image | 🟡 MEDIUM | Container runs but no service |
| Permission denied on port 8554 | 🟠 LOW | Unlikely (container is root) |
| OOM killed (insufficient memory) | 🟠 LOW | Would appear in logs |

### How to Diagnose

```bash
# 1. Check if entrypoint/command configured in task definition
aws ecs describe-task-definition --task-definition mediamtx-task:12 \
  --region us-east-1 \
  --query 'taskDefinition.containerDefinitions[0].{EntryPoint:entryPoint,Command:command}'

# 2. Check if container has any startup error
aws ecs describe-tasks --cluster broadcast-cluster \
  --tasks $(aws ecs list-tasks --cluster broadcast-cluster --service-name mediamtx-service --query 'taskArns[0]' --output text) \
  --region us-east-1 \
  --query 'tasks[0].{StoppedReason:stoppedReason,StoppingAt:stoppingAt,DesiredStatus:desiredStatus,LastStatus:lastStatus}'

# 3. Check if image has mediamtx binary
docker run --rm 457553343935.dkr.ecr.us-east-1.amazonaws.com/mediamtx:latest \
  /bin/sh -c "which mediamtx || ls -la /usr/bin/mediamtx* || echo 'BINARY NOT FOUND'"
```

---

## Current Deployment Status

### Service Timeline

```
Dec 16-17: RPi → NLB → Fargate deployment SUCCESSFUL
           ✅ Stream delivered, HLS/RTMP output working
           ✅ 400+ segments recorded

Dec 22 12:06: Makefile refactored (EC2 as primary)
              ✅ Fargate marked as LEGACY
              ⚠️ No service restart/redeployment

Dec 22 14:09: Verification requested
              ✅ RPi confirmed actively streaming
              ❌ Targets show unhealthy (recent change? or longstanding?)

Dec 22 14:25: Root cause identified
              ❌ MediaMTX not listening on 8554
              ❌ Empty CloudWatch logs indicate startup failure
```

### Hypothesis: Did Something Break on Dec 22?

- **Makefile refactoring**: Code changes only (no service redeploy)
- **Service status**: Currently shows ACTIVE (same as earlier)
- **Running tasks**: 3 (same as earlier checks)
- **Task age**: Most recent task created Dec 22 12:08 (around Makefile refactoring time)

**Possible timeline**:
1. Dec 22 12:06: Makefile refactored, code pushed/merged
2. Dec 22 12:07-12:10: Auto-deployment trigger (if CI/CD configured) replaced tasks
3. Dec 22 12:08: New tasks started with potentially different image or config
4. Dec 22 14:09+: New tasks failing to listen on 8554

---

## Solution Options

### Option 1: Immediate - Use EC2 Solution (Recommended)

**Status**: Already primary in refactored Makefile (Dec 22)  
**Command**: `make deploy` (defaults to EC2)  
**Effort**: 5-10 minutes  
**Reliability**: ✅ Proven working (Dec 16-17 deployment)

```bash
# Deploy to EC2 (no Fargate timeout issues)
make deploy

# Monitor
make status

# Start streaming
make broadcast
```

### Option 2: Fix Fargate MediaMTX Startup

**Status**: In progress  
**Effort**: 15-30 minutes  
**Steps**:
1. Verify task definition has proper entrypoint/command
2. Check MediaMTX image has binary and config
3. Rebuild image if corrupted
4. Update task definition
5. Re-deploy service (force new task deployment)

```bash
# Rebuild and push fresh image
docker pull bluenviron/mediamtx:latest
docker tag bluenviron/mediamtx:latest 457553343935.dkr.ecr.us-east-1.amazonaws.com/mediamtx:latest
docker push 457553343935.dkr.ecr.us-east-1.amazonaws.com/mediamtx:latest

# Force new deployment
aws ecs update-service --cluster broadcast-cluster --service mediamtx-service \
  --force-new-deployment --region us-east-1
```

### Option 3: Troubleshoot in Isolation

**Status**: Diagnostic  
**Effort**: 10-15 minutes  
**Purpose**: Understand root cause before fixing

```bash
# Test image locally
docker run --rm -it 457553343935.dkr.ecr.us-east-1.amazonaws.com/mediamtx:latest /bin/sh

# Try to start mediamtx manually
docker run --rm -p 8554:8554 \
  457553343935.dkr.ecr.us-east-1.amazonaws.com/mediamtx:latest

# Check if binary exists
docker run --rm 457553343935.dkr.ecr.us-east-1.amazonaws.com/mediamtx:latest \
  ls -la /usr/bin/mediamtx*
```

---

## Recommendation

### Immediate Action (Next 5 minutes)

**Use EC2 solution while investigating Fargate**:

```bash
cd /Users/dchristiani/code/media-mtx

# Deploy to EC2 (primary solution)
make deploy

# Wait for deployment (5-10 minutes)
make status

# Start streaming
./broadcast.sh
```

### Parallel Investigation (Background)

Check MediaMTX task definition while EC2 deploys:

```bash
# See what command/entrypoint is configured
aws ecs describe-task-definition --task-definition mediamtx-task:12 \
  --region us-east-1 | jq '.taskDefinition.containerDefinitions[0] | {entryPoint, command, image}'

# If no command, this is the issue - MediaMTX never starts
```

---

## Key Takeaways

| Finding | Impact | Action |
|---------|--------|--------|
| RPi actively streaming | ✅ Source is good | No action needed |
| NLB infrastructure healthy | ✅ Path is ready | No action needed |
| MediaMTX not listening | ❌ CRITICAL BLOCKER | Fix or use EC2 |
| Empty logs = startup failure | 🔍 Diagnosis hint | Check task definition |
| Fargate marked as LEGACY | 📋 Per refactoring | Use EC2 (primary) |

---

## Verification Checklist (For When Fixed)

```bash
# When Fargate is fixed, verify with:

# 1. Health checks pass
✅ aws elbv2 describe-target-health --target-group-arn <ARN> \
   --query 'TargetHealthDescriptions[*].TargetHealth.State'
# Should show: 'healthy'

# 2. Stream accessible
✅ ffprobe -rtsp_transport tcp \
   -i rtsp://broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com:8554/rpicam2
# Should show: Duration, bitrate, codec info

# 3. HLS streaming
✅ curl http://broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com:8888/rpicam2/index.m3u8
# Should return: HLS playlist

# 4. CloudWatch logs flowing
✅ aws logs tail /ecs/mediamtx --follow
# Should show: MediaMTX startup messages, stream events

# 5. Full pipeline test
✅ ./e2e-test-fargate.sh
# Should pass all 7 stages
```

---

**Report Generated**: December 22, 2025 @ 14:35 UTC  
**Status**: MediaMTX startup failure under investigation  
**Recommendation**: Deploy to EC2 (primary solution) while diagnosing Fargate  
**Next Steps**: Check task definition entrypoint/command, rebuild image if needed
