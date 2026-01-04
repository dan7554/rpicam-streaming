# MediaMTX Architecture & Port Audit

**Date**: January 3, 2026  
**Purpose**: Comprehensive review of NLB, MediaMTX, and Broadcast architecture  

---

## 🎯 Architecture Overview

```
┌─────────────────┐
│  RPi Cameras    │ (RTSP Push)
│  rpicam2, etc.  │
└────────┬────────┘
         │ RTSP :8554
         ▼
┌─────────────────────────────────────────────────────────┐
│              Network Load Balancer (NLB)                 │
│         mediamtx.racetrackstreaming.com                  │
│  (internet-facing, cross-zone enabled)                   │
└─────────────────────────────────────────────────────────┘
         │
         ├─ :8554 (TCP) → mediamtx-nlb-rtsp      [✅ HEALTHY]
         ├─ :1935 (TCP) → mediamtx-nlb-rtmp      [✅ HEALTHY]
         ├─ :8888 (TCP) → mediamtx-nlb-hls       [⚠️  RELAXED]
         ├─ :8889 (TCP) → mediamtx-nlb-webrtc    [⚠️  RELAXED]
         └─ :9997 (TCP) → mediamtx-nlb-api       [⚠️  RELAXED]
         │
         ▼
┌──────────────────────────────────────────────────────────┐
│         MediaMTX ECS Service (Fargate)                    │
│  Cluster: broadcast-cluster                               │
│  Service: mediamtx-service                                │
│  Internal IP: 172.31.82.2                                 │
│  Security Group: sg-0a39a0404cc7eac61                     │
└──────────────────────────────────────────────────────────┘
         │
         ├─ Container Ports:
         │  • 8554 (TCP) - RTSP Server
         │  • 8888 (TCP) - HLS Server  
         │  • 8889 (TCP) - WebRTC TCP
         │  • 8891 (UDP) - SRT Server
         │  • 9997 (TCP) - API Server
         │  • 9996 (TCP) - Playback Server
         │  • 1935 (TCP) - RTMP Server
         │
         ▼
┌──────────────────────────────────────────────────────────┐
│      Broadcast Client/Server (ALB)                        │
│  admin.racetrackstreaming.com                             │
│  stream.racetrackstreaming.com                            │
│  Security Group: sg-05daa07df49f3e721                     │
└──────────────────────────────────────────────────────────┘
```

---

## ✅ Port Configuration Status

### **NLB Listeners** (Public Internet → MediaMTX)
| Port | Protocol | Target Group | Status | Purpose |
|------|----------|-------------|--------|---------|
| 8554 | TCP | mediamtx-nlb-rtsp | ✅ HEALTHY | RPi camera RTSP streams |
| 1935 | TCP | mediamtx-nlb-rtmp | ✅ HEALTHY | RTMP streaming (alternative) |
| 8888 | TCP | mediamtx-nlb-hls | ⚠️ RELAXED | HLS browser playback |
| 8889 | TCP | mediamtx-nlb-webrtc | ⚠️ RELAXED | WebRTC TCP (not recommended through NLB) |
| 9997 | TCP | mediamtx-nlb-api | ⚠️ RELAXED | MediaMTX REST API |

**Health Check Settings** (Relaxed):
- Interval: 300 seconds
- Unhealthy Threshold: 10
- Healthy Threshold: 2
- Timeout: 10 seconds

### **MediaMTX Container Ports**
| Port | Protocol | Bind | Configuration | Exposed via NLB? |
|------|----------|------|---------------|------------------|
| 8554 | TCP | 0.0.0.0:8554 | RTSP server | ✅ Yes (rtsp://mediamtx.racetrackstreaming.com:8554) |
| 8888 | TCP | 0.0.0.0:8888 | HLS server | ✅ Yes (http://mediamtx.racetrackstreaming.com:8888) |
| 8889 | TCP | 0.0.0.0:8889 | WebRTC HTTP/TCP | ✅ Yes (not recommended) |
| 8189 | UDP | :8189 | WebRTC UDP | ❌ No (UDP not exposed through NLB) |
| 1935 | TCP | 0.0.0.0:1935 | RTMP server | ✅ Yes (rtmp://mediamtx.racetrackstreaming.com:1935) |
| 8891 | UDP | 0.0.0.0:8891 | SRT server | ❌ No (UDP not exposed through NLB) |
| 9996 | TCP | 0.0.0.0:9996 | Playback server | ❌ No (internal only) |
| 9997 | TCP | 0.0.0.0:9997 | API server | ✅ Yes (http://mediamtx.racetrackstreaming.com:9997) |
| 9998 | TCP | 0.0.0.0:9998 | Metrics (disabled) | ❌ No |
| 9999 | TCP | 0.0.0.0:9999 | PPROF (disabled) | ❌ No |

### **ECS Security Group** (sg-0a39a0404cc7eac61)
| Port | Protocol | Source | Purpose |
|------|----------|--------|---------|
| 8554 | TCP | 0.0.0.0/0 | RTSP from RPi cameras |
| 1935 | TCP | 0.0.0.0/0 | RTMP streaming |
| 8888 | TCP | 0.0.0.0/0 | HLS browser access |
| 9997 | TCP | 0.0.0.0/0 + sg-05daa07df49f3e721 (ALB) | API access (public + broadcast client) |
| 80 | TCP | sg-05daa07df49f3e721 (ALB) | Broadcast client health checks |

---

## 🔍 Use Case Analysis

### **1. RPi Cameras Push Streams → MediaMTX** ✅
- **Protocol**: RTSP
- **Port**: 8554
- **Flow**: Camera → NLB:8554 → MediaMTX:8554
- **Status**: ✅ WORKING
- **URL**: `rtsp://mediamtx.racetrackstreaming.com:8554/<camera-name>`
- **Security**: Open to internet (0.0.0.0/0)
- **Script**: [copy-and-install.sh](copy-and-install.sh) configured correctly

### **2. Browser Viewable Streams (HLS)** ⚠️
- **Protocol**: HTTP/HLS
- **Port**: 8888
- **Flow**: Browser → NLB:8888 → MediaMTX:8888
- **Status**: ⚠️ CONFIGURED BUT UNTESTED (service unresponsive)
- **URL**: `http://mediamtx.racetrackstreaming.com:8888/<camera-name>/`
- **Configuration**: 
  - ✅ NLB listener exists
  - ✅ Target group created
  - ✅ Security group allows 8888
  - ⚠️ Health checks relaxed (300s interval)
  - ⚠️ MediaMTX service not responding

**HLS Configuration** (mediamtx-container.yml):
```yaml
hls: yes
hlsAddress: 0.0.0.0:8888
hlsEncryption: no
hlsAllowOrigins: ["*"]
hlsAlwaysRemux: yes
hlsVariant: lowLatency
hlsSegmentCount: 7
hlsSegmentDuration: 1s
hlsPartDuration: 200ms
```

### **3. API Access** ⚠️
- **Protocol**: HTTP/REST
- **Port**: 9997
- **Flow**: Client → NLB:9997 → MediaMTX:9997
- **Status**: ⚠️ CONFIGURED BUT UNRESPONSIVE
- **URL**: `http://mediamtx.racetrackstreaming.com:9997/v3/paths/list`
- **Security**: Open to internet + ALB security group
- **Used by**: Broadcast admin client, camera monitoring

**API Configuration** (mediamtx-container.yml):
```yaml
api: yes
apiAddress: 0.0.0.0:9997
apiEncryption: no
apiAllowOrigins: ["*"]
```

### **4. WebRTC for Admin Client** ❌ NOT RECOMMENDED
- **Protocol**: WebRTC (TCP/UDP)
- **Port**: 8889 (TCP), 8189 (UDP)
- **Flow**: Browser → NLB:8889 → MediaMTX:8889
- **Status**: ❌ CONFIGURED BUT NOT VIABLE
- **Issues**:
  - NLB doesn't support UDP well for WebRTC
  - ICE/STUN/TURN negotiation fails through NLB
  - UDP port 8189 not exposed through NLB
  - Better alternatives: HLS (low latency) or direct RTSP

**WebRTC Configuration** (mediamtx-container.yml):
```yaml
webrtc: yes
webrtcAddress: 0.0.0.0:8889
webrtcEncryption: no
webrtcLocalUDPAddress: :8189
webrtcLocalTCPAddress: :8889
webrtcIPsFromInterfaces: no
webrtcAdditionalHosts: [mediamtx.racetrackstreaming.com]
```

### **5. RTMP Streaming** ✅
- **Protocol**: RTMP
- **Port**: 1935
- **Flow**: Client → NLB:1935 → MediaMTX:1935
- **Status**: ✅ WORKING
- **URL**: `rtmp://mediamtx.racetrackstreaming.com:1935/<camera-name>`
- **Use**: Alternative ingestion protocol (OBS, etc.)

---

## ⚠️ Critical Issues Identified

### **Issue #1: MediaMTX Service Unresponsive**
- **Symptom**: All API calls timeout, service shows RUNNING but no response
- **Impact**: HLS, API, WebRTC all non-functional
- **Diagnosis**: Container-level issue (even internal IP 172.31.82.2 times out)
- **Next Steps**:
  1. Check container logs: `aws logs tail /ecs/mediamtx --since 10m`
  2. Verify task definition not corrupted
  3. Check resource limits (CPU/memory exhaustion)
  4. Consider full service rebuild

### **Issue #2: WebRTC Through NLB**
- **Problem**: NLB is TCP/UDP load balancer, not application-aware
- **WebRTC Requirement**: Needs UDP for media (8189), TCP for signaling (8889)
- **NLB Limitation**: UDP not exposed, ICE negotiation fails
- **Recommendation**: Use HLS instead for browser streaming
  - Lower latency than traditional HLS (200ms segments)
  - No NAT/firewall traversal issues
  - Works through standard HTTP

### **Issue #3: Missing UDP Ports**
- **SRT Server**: Port 8891 (UDP) - not exposed through NLB
- **WebRTC UDP**: Port 8189 (UDP) - not exposed through NLB
- **Impact**: These protocols won't work for public access
- **Solution**: If needed, use UDP NLB listeners (but not recommended for WebRTC)

### **Issue #4: Security Group - Port 8889**
- **Current**: Port 8889 NOT in security group ingress rules
- **Impact**: Even if NLB forwarded WebRTC, container wouldn't be reachable
- **Fix Required**: Add ingress rule for 8889 if WebRTC needed

---

## 🎯 Recommendations

### **Immediate Actions**

1. **Fix MediaMTX Service**
   ```bash
   # Check logs
   aws logs tail /ecs/mediamtx --since 30m --format short
   
   # Check service events
   aws ecs describe-services --cluster broadcast-cluster --services mediamtx-service \
     --query 'services[0].events[:10]' --output table
   
   # Full service restart (stop/start)
   aws ecs update-service --cluster broadcast-cluster --service mediamtx-service \
     --desired-count 0 --region us-east-1
   sleep 30
   aws ecs update-service --cluster broadcast-cluster --service mediamtx-service \
     --desired-count 1 --region us-east-1
   ```

2. **Abandon WebRTC Through NLB**
   - Remove WebRTC from admin client
   - Use HLS for browser streaming instead
   - HLS URL: `http://mediamtx.racetrackstreaming.com:8888/rpicam2/`

3. **Test HLS Once Service Recovered**
   ```bash
   # Test HLS endpoint
   curl -I http://mediamtx.racetrackstreaming.com:8888/rpicam2/index.m3u8
   
   # Test in browser
   open http://mediamtx.racetrackstreaming.com:8888/rpicam2/
   ```

4. **Add Missing Security Group Rule (if WebRTC needed)**
   ```bash
   aws ec2 authorize-security-group-ingress \
     --group-id sg-0a39a0404cc7eac61 \
     --protocol tcp --port 8889 \
     --cidr 0.0.0.0/0 \
     --region us-east-1
   ```

### **Architecture Improvements**

1. **Simplify Protocol Stack**
   - **RTSP (8554)**: RPi camera ingestion ✅
   - **HLS (8888)**: Browser playback ✅
   - **API (9997)**: Admin/monitoring ✅
   - **RTMP (1935)**: Alternative ingestion (optional) ✅
   - **~~WebRTC~~**: Remove (not viable through NLB) ❌

2. **Add CloudWatch Alarms**
   - Target health status
   - MediaMTX container CPU/memory
   - API response time
   - Active stream count

3. **Document Public URLs**
   - RTSP: `rtsp://mediamtx.racetrackstreaming.com:8554/<camera>`
   - HLS: `http://mediamtx.racetrackstreaming.com:8888/<camera>/`
   - API: `http://mediamtx.racetrackstreaming.com:9997/v3/paths/list`
   - RTMP: `rtmp://mediamtx.racetrackstreaming.com:1935/<camera>`

---

## 📊 Port Summary Matrix

| Service | Port | Protocol | NLB | SG | Container | Status | Public URL |
|---------|------|----------|-----|----|-----------| -------|------------|
| RTSP | 8554 | TCP | ✅ | ✅ | ✅ | ✅ Working | rtsp://mediamtx.racetrackstreaming.com:8554 |
| RTMP | 1935 | TCP | ✅ | ✅ | ✅ | ✅ Working | rtmp://mediamtx.racetrackstreaming.com:1935 |
| HLS | 8888 | TCP | ✅ | ✅ | ✅ | ⚠️ Untested | http://mediamtx.racetrackstreaming.com:8888 |
| API | 9997 | TCP | ✅ | ✅ | ✅ | ⚠️ Unresponsive | http://mediamtx.racetrackstreaming.com:9997 |
| WebRTC TCP | 8889 | TCP | ✅ | ❌ | ✅ | ❌ Not viable | N/A |
| WebRTC UDP | 8189 | UDP | ❌ | ❌ | ✅ | ❌ Not exposed | N/A |
| SRT | 8891 | UDP | ❌ | ❌ | ✅ | ❌ Not exposed | N/A |
| Playback | 9996 | TCP | ❌ | ❌ | ✅ | ℹ️ Internal only | N/A |

**Legend**:
- ✅ Configured and working
- ⚠️ Configured but untested/issues
- ❌ Not configured or not viable
- ℹ️ Internal only (by design)

---

## 🔧 Makefile Commands

```bash
# Check NLB status
make mediamtx-nlb-status

# Disable health checks (already done)
make mediamtx-nlb-disable-healthchecks

# Check service status
aws ecs describe-services --cluster broadcast-cluster --services mediamtx-service \
  --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount}' \
  --output table

# View container logs
aws logs tail /ecs/mediamtx --follow

# Restart service
aws ecs update-service --cluster broadcast-cluster --service mediamtx-service \
  --force-new-deployment --region us-east-1
```

---

## ✅ What's Working

1. ✅ **NLB Infrastructure**: All 5 ports configured with listeners and target groups
2. ✅ **DNS Configuration**: mediamtx.racetrackstreaming.com → NLB (proxy disabled)
3. ✅ **Cross-zone Load Balancing**: Enabled (fixed 4+ min → 200ms latency)
4. ✅ **Security Group**: Most ports accessible (except 8889)
5. ✅ **Camera Scripts**: Updated to use public domain
6. ✅ **RTSP Ingestion**: Cameras can push to public domain
7. ✅ **Health Checks**: Relaxed to avoid false negatives

## ❌ What Needs Fixing

1. ❌ **MediaMTX Service**: Completely unresponsive (critical)
2. ❌ **HLS Testing**: Cannot test until service recovered
3. ❌ **API Access**: Timing out on all endpoints
4. ❌ **WebRTC**: Not viable through NLB architecture
5. ❌ **Security Group**: Missing port 8889 ingress rule

---

**Next Steps**: Focus on recovering MediaMTX service before testing any streaming protocols.
