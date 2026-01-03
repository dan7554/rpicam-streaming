# MediaMTX Health Check Architecture

## Overview

The MediaMTX infrastructure uses a **two-layer health check system**:

1. **Container-level health checks** (ECS native)
2. **Load balancer health checks** (NLB/ELB)

These work together to ensure service availability and automatic recovery.

---

## Layer 1: Container Health Checks (ECS)

### Configuration
```json
{
  "command": ["CMD-SHELL", "curl -f http://localhost:9997/ || exit 1"],
  "interval": 30,
  "timeout": 5,
  "retries": 3,
  "startPeriod": 15
}
```

### How It Works

| Parameter | Value | Meaning |
|-----------|-------|---------|
| **command** | `curl -f http://localhost:9997/` | Probes MediaMTX API on port 9997 (fails on non-2xx responses) |
| **interval** | 30s | Health check runs every 30 seconds |
| **timeout** | 5s | Must respond within 5 seconds |
| **retries** | 3 | Task marked unhealthy after 3 consecutive failures |
| **startPeriod** | 15s | Grace period before checks start (container startup time) |

### Failure Behavior

When a container fails 3 consecutive health checks:
- ECS marks the task as **unhealthy**
- The running task **continues** (does NOT auto-restart)
- NLB is notified via target deregistration
- Service may replace the task based on deployment strategy

### Health Check Endpoint

The health check probes:
```
GET http://localhost:9997/
```

This endpoint:
- ✅ **Returns** HTTP 200 when MediaMTX API is responsive
- ❌ **Returns** non-2xx status if API is down
- ❌ **Times out** if container is hung or unresponsive

---

## Layer 2: NLB Target Group Health Checks

### Three Target Groups Configured

#### 1. **mediamtx-rtsp** (RTSP Streaming)
```
Protocol:            TCP
Port:               8554
Health Check:       TCP on port 8554
Interval:           30 seconds
Timeout:            2 seconds
Healthy Threshold:  3 consecutive passes
Unhealthy Threshold: 3 consecutive failures
Current Health:     2 healthy, 1 unhealthy, 2 draining
```

**What it checks**: 
- Opens TCP connection to port 8554 (RTSP listener)
- If connection succeeds within 2 seconds → HEALTHY
- No payload sent (pure TCP three-way handshake)

#### 2. **mediamtx-rtmp** (RTMP Streaming)
```
Protocol:            TCP
Port:               1935
Health Check:       TCP on port 1935
Interval:           30 seconds
Timeout:            10 seconds (more lenient)
Healthy Threshold:  3 consecutive passes
Unhealthy Threshold: 3 consecutive failures
Current Health:     1 healthy, 4 unhealthy
```

**What it checks**:
- Opens TCP connection to port 1935 (RTMP listener)
- 10-second timeout (more forgiving for RTMP protocol)

#### 3. **mediamtx-hls** (HLS Streaming)
```
Protocol:            TCP
Port:               8888
Health Check:       HTTP on port 9997 (!)
Interval:           30 seconds
Timeout:            6 seconds
Healthy Threshold:  5 consecutive passes
Unhealthy Threshold: 2 consecutive failures
Current Health:     0 healthy, 2 unhealthy, 3 draining
```

**What it checks** (⚠️ MISCONFIGURED):
- Sends HTTP GET request to port 9997 (not 8888)
- Path: `/`
- Should check port 8888 (the actual HLS port)
- This mismatch causes false failures

---

## Current Target Health Status

### RTSP Target Group
```
172.31.89.200:8554   → HEALTHY ✅
172.31.95.194:8554   → HEALTHY ✅
172.31.80.127:8554   → DRAINING (deregistration in progress)
172.31.84.8:8554     → UNHEALTHY ❌ (failed health checks)
172.31.88.76:8554    → DRAINING (deregistration in progress)
```

### RTMP Target Group
```
1 target             → HEALTHY ✅
4 targets            → UNHEALTHY ❌ (failed health checks)
```

### HLS Target Group
```
0 targets            → HEALTHY
2 targets            → UNHEALTHY ❌
3 targets            → DRAINING
```

---

## Health Check Flow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                      NLB Listener                           │
│              (Internet traffic for streams)                 │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ├─────────────────────────────────────┐
                        │                                     │
            ┌───────────▼──────────┐          ┌──────────────▼────────┐
            │  Target Group        │          │  Target Group         │
            │  mediamtx-rtsp       │          │  mediamtx-rtmp        │
            │  (Port 8554)         │          │  (Port 1935)          │
            │                      │          │                       │
            │ Health: TCP:8554     │          │ Health: TCP:1935      │
            │ Interval: 30s        │          │ Interval: 30s         │
            │ Timeout: 2s          │          │ Timeout: 10s          │
            └───────────┬──────────┘          └──────────┬────────────┘
                        │                               │
        ┌───────────────┼───────────────────────────────┼──────────────┐
        │               │                               │              │
    ┌───▼────┐      ┌───▼────┐      ┌────────┐    ┌────▼────┐     ┌──▼────┐
    │ Task 1 │      │ Task 2 │      │ Task 3 │    │ Task 4  │     │Task 5 │
    │ Port   │      │ Port   │      │ (Drain)│    │ (Unhea- │     │(Drain)│
    │ 8554   │      │ 8554   │      │        │    │ lthy)   │     │       │
    │ ✅     │      │ ✅     │      │ 🔄     │    │ ❌      │     │ 🔄    │
    │        │      │        │      │        │    │        │     │       │
    │ PORT   │      │ PORT   │      │ PORT   │    │ PORT   │     │ PORT  │
    │ 9997   │      │ 9997   │      │ 9997   │    │ 9997   │     │ 9997  │
    │        │      │        │      │        │    │        │     │       │
    │┌──────┐│      │┌──────┐│      │┌──────┐│    │┌──────┐│     │┌──────┐│
    ││Health││      ││Health││      ││Health││    ││Health││     ││Health││
    ││Check ││      ││Check ││      ││Check ││    ││Check ││     ││Check ││
    ││✅    ││      ││✅    ││      ││🔄    ││    ││❌    ││     ││🔄    ││
    ││Every ││      ││Every ││      ││Every ││    ││Every ││     ││Every ││
    ││30s  ││      ││30s  ││      ││30s  ││    ││30s  ││     ││30s  ││
    │└──────┘│      │└──────┘│      │└──────┘│    │└──────┘│     │└──────┘│
    └────────┘      └────────┘      └────────┘    └────────┘     └────────┘
      Container                                       Container
      Health: ✅                                      Health: ❌
      (curl port 9997 passing)                       (curl port 9997 failing)
```

---

## Health Check Sequence of Events

### Scenario: Task Is Healthy

```
Time  |  Container Health Check           |  NLB Health Check (RTSP)
------|-----------------------------------|--------------------------
 0s   | Start container                   |
15s   | Start health checks               |
30s   | ✅ PASS curl localhost:9997/     | ✅ TCP port 8554 OK
60s   | ✅ PASS curl localhost:9997/     | ✅ TCP port 8554 OK
90s   | ✅ PASS curl localhost:9997/     | ✅ TCP port 8554 OK → HEALTHY
120s  | ✅ PASS (continues)               | ✅ TCP port 8554 OK (continues)
```

**Result**: Task is marked HEALTHY by both ECS and NLB, traffic flows normally.

---

### Scenario: Container Unresponsive (API Down)

```
Time  |  Container Health Check           |  NLB Health Check (RTSP)
------|-----------------------------------|--------------------------
80s   | ✅ PASS curl localhost:9997/     | ✅ TCP port 8554 OK
110s  | ❌ FAIL curl localhost:9997/     | ✅ TCP port 8554 still open
140s  | ❌ FAIL #2                        | ✅ TCP port 8554 still open
170s  | ❌ FAIL #3 → UNHEALTHY            | ✅ TCP port 8554 still open
200s  | (Task stays running)              | ❌ Now fails (after timeout)
```

**Result**: 
- Container marked UNHEALTHY after 3 failures (~170s)
- Task **continues running** (ECS doesn't auto-restart)
- NLB detects issue after timeout
- NLB drains connections (new traffic not routed)
- Service may replace the task (if scaling policy configured)

---

## Why Different Health Checks?

### Container Health Checks (ECS)
- **Purpose**: Detect application-level failures (API not responding)
- **Advantage**: Understands MediaMTX application logic
- **Limitation**: Only affects ECS task lifecycle, not traffic routing

### NLB Health Checks
- **Purpose**: Detect network/port availability for traffic routing
- **Advantage**: Fast, network-level detection
- **Limitation**: Only checks port is open, not if service works correctly

### Why Both?
- **Container checks** catch: API crashes, memory issues, infinite loops
- **NLB checks** catch: Network failures, port binding issues
- Together they provide defense-in-depth

---

## Issues Currently Present

### 🔴 HLS Target Group Misconfiguration

The `mediamtx-hls` target group is checking the **wrong port**:

```
Target Group Port:     8888 (HLS HTTP streaming)
Health Check Port:     9997 (MediaMTX API)
```

This causes:
- Health checks fail because port 9997 is not meant to serve HLS
- Targets get marked unhealthy incorrectly
- Valid HLS streams don't get traffic

**Fix needed**:
```bash
aws elbv2 modify-target-group \
  --target-group-arn arn:aws:elasticloadbalancing:us-east-1:457553343935:targetgroup/mediamtx-hls/0d80715cec5ccc31 \
  --health-check-protocol TCP \
  --health-check-port 8888 \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 3 \
  --unhealthy-threshold-count 3 \
  --region us-east-1
```

### 🟡 Unhealthy Targets

- **RTSP group**: 1 unhealthy (172.31.84.8)
- **RTMP group**: 4 unhealthy
- **HLS group**: 2 unhealthy

**Possible causes**:
1. Port misconfiguration (HLS issue)
2. Target tasks not running or crashed
3. Container health checks failing
4. Network connectivity issues

**Investigation needed**:
```bash
# Check task status
aws ecs describe-tasks --cluster broadcast-cluster \
  --tasks arn:aws:ecs:us-east-1:457553343935:task/broadcast-cluster/[task-id] \
  --region us-east-1

# Check container logs
aws logs tail /ecs/mediamtx --region us-east-1 --since 5m
```

---

## Health Check Behavior Summary

| Check Type | What's Checked | Interval | Detects | Action |
|------------|---|----------|---------|--------|
| **Container (ECS)** | API on 9997 | 30s | App failure | Mark unhealthy, may replace task |
| **NLB RTSP** | TCP 8554 | 30s | Port down | Drain traffic (2s timeout) |
| **NLB RTMP** | TCP 1935 | 30s | Port down | Drain traffic (10s timeout) |
| **NLB HLS** | HTTP 9997* | 30s | API failure | Drain traffic (6s timeout) |

*HLS health check should be on port 8888, not 9997 (misconfiguration)

---

## Recommended Health Check Strategy

### Current (Two-Layer)
```
✅ Container Health Check (ECS)  → Detects application failures
↓
✅ NLB Health Checks              → Detects network/port issues
↓
🔄 Task Replacement (ECS)        → Replaces failed tasks
```

### Suggested Improvements

1. **Fix HLS health check** to use port 8888 with TCP protocol
2. **Lower failure thresholds** to detect issues faster:
   - Reduce healthy threshold from 5 to 3
   - Reduce timeout from 6s to 2s (consistent with others)
3. **Add CloudWatch alarms** for unhealthy target alerts
4. **Implement auto-remediation** Lambda to restart unhealthy containers

---

## Testing Health Checks

### Test Container Health Check
```bash
# SSH into task and simulate API failure
aws ecs execute-command \
  --cluster broadcast-cluster \
  --task <task-arn> \
  --container mediamtx \
  --command "ps aux | grep -i mediamtx" \
  --interactive

# Verify health check would fail
curl http://localhost:9997/ 2>&1
```

### Test NLB Health Check
```bash
# From a machine in the VPC:
nc -zv 172.31.89.200 8554   # RTSP
nc -zv 172.31.89.200 1935   # RTMP
nc -zv 172.31.89.200 8888   # HLS
nc -zv 172.31.89.200 9997   # API
```

### Monitor Health in Real-Time
```bash
# Watch target health transitions
watch -n 2 'aws elbv2 describe-target-health \
  --target-group-arn arn:aws:elasticloadbalancing:us-east-1:457553343935:targetgroup/mediamtx-rtsp/7d6fac9b9e2489d1 \
  --region us-east-1 | jq ".TargetHealthDescriptions[] | {Id, State, Reason}"'
```

---

## Summary

MediaMTX uses a robust two-layer health check system:

1. **Container health checks** probe the API every 30s, marking tasks unhealthy after 3 failures
2. **NLB health checks** verify port accessibility every 30s for traffic routing decisions
3. **Current issue**: HLS target group checks wrong port (9997 instead of 8888)
4. **Result**: Multiple unhealthy targets due to misconfiguration

The architecture is sound, but the HLS misconfiguration needs immediate correction for full operational capability.
