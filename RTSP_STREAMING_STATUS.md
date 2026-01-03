# RTSP Streaming Status Report

**Date**: December 16, 2025  
**Status**: Partially Working - Infrastructure Ready, Network Bridge Needed

## What's Working

### RPi Camera Capture
- ✅ rpicam-vid outputs h264 to named FIFO (`/tmp/camera.h264`)
- ✅ rpicam-vid with --flush flag properly encodes with SPS/PPS headers
- ✅ H264 stream contains valid video (1280x720, 30fps, h264 High profile)

### ffmpeg Processing
- ✅ ffmpeg reads h264 from FIFO successfully
- ✅ ffmpeg detects video codec parameters: "h264 (High), yuv420p(tv, bt709, progressive), 1280x720, 25 fps"
- ✅ ffmpeg can copy codec (-c:v copy) without re-encoding
- ✅ ffmpeg RTSP output format works (-f rtsp)

### MediaMTX Infrastructure
- ✅ MediaMTX running on ECS Fargate (2 tasks)
- ✅ RTSP listener active on port 8554
- ✅ Task definition includes rpicam2 path configured as "publisher" (accepts push)
- ✅ Task definition includes MTX_RTMPADDRESS=:1935 for RTMP support
- ✅ Environment: TCP-based RTSP transport configured

### Load Balancing
- ✅ ALB (Application Load Balancer) running with HTTPS/HTTP listeners
- ✅ NLB (Network Load Balancer) running for RTMP on port 1935
- ✅ NLB has 4 MediaMTX tasks registered as targets (2 currently healthy)

### RPi Service
- ✅ rpicam-stream.service running and auto-restarting on failure
- ✅ Script properly handles FIFO lifecycle (create/cleanup)
- ✅ Logging output captures ffmpeg and rpicam-vid diagnostics

## What's Not Working

### Network Connectivity RPi → MediaMTX
- ❌ RPi (Tailscale network: 100.80.96.23) cannot reach:
  - AWS NLB public endpoint (timeout after 5 seconds)
  - AWS ALB on port 8554 (no listener configured)
  - Direct AWS private IPs (not routable from Tailscale)

### RTSP Push Endpoint
- ❌ `rtsp://stream.racetrackstreaming.com:8554/rpicam2` → Connection fails
  - ALB doesn't have port 8554 listener
  - NLB only listens on port 1935 (RTMP, not RTSP)
  - RPi can't route through public AWS endpoints from Tailscale

## Current Error
```
[2025-12-16 18:42:01] Stream #0:0 -> #0:0 (copy)
[2025-12-16 18:42:01] Stream ended, cleaning up...
```
ffmpeg successfully parses the stream but fails to establish output connection to RTSP server.

## Root Cause Analysis

**Issue**: Network isolation between two independent networks
- **RPi Side**: Connected via Tailscale (100.x.x.x private network)
- **MediaMTX Side**: Running on AWS Fargate (172.31.x.x private + ALB/NLB public endpoints)
- **Gap**: No bridge configured between networks

**Why Previous Attempts Failed**:
1. **Direct private IP** (172.31.93.34:8554): Not routable from Tailscale
2. **NLB public endpoint**: RPi cannot establish TCP connection (firewall/routing)
3. **ALB on port 8554**: ALB has no listener for port 8554
4. **Domain resolution**: `stream.racetrackstreaming.com` resolves to ALB, but ALB can't route RTSP

## Solutions (In Priority Order)

### Solution 0: ✅ COMPLETED - Added NLB RTSP Listener
Created TCP listener on NLB for port 8554 pointing to MediaMTX target group.

**Status**: 
- ✅ Target group `mediamtx-rtsp` created (port 8554, TCP)
- ✅ 4 MediaMTX task IPs registered as targets
- ✅ NLB listener active on port 8554
- ⏳ **BLOCKED**: RPi cannot reach NLB public endpoint from Tailscale network

**Root Issue**: Network isolation between Tailscale (RPi) and AWS (NLB/MediaMTX)

### Solution 1: Use Local Relay (RECOMMENDED FOR IMMEDIATE USE)
Deploy MediaMTX locally (docker-compose on local machine or dedicated relay server) to accept RTSP push from RPi via public internet or Tailscale. Cloud system pulls from local.

**Setup**:
```bash
# On local machine (accessible to RPi via public IP or Tailscale)
cd broadcast-system
docker-compose up -d mediamtx

# RPi script targets local MediaMTX
# Then cloud system can pull via RTSP or HTTP
```

**Pros**: 
- Works immediately without network configuration
- Familiar local development environment
- Can test full pipeline locally
- Can use Tailscale DNS if local machine is on Tailscale

**Cons**: 
- Requires local machine to be always on
- Not suitable for production without proper infrastructure
- Single point of failure

### Solution 2: Expose MediaMTX Task IP
Get a public elastic IP for one MediaMTX task and route port 8554 directly
```bash
# Assign elastic IP to a MediaMTX task's ENI
aws ec2 allocate-address --domain vpc
aws ec2 associate-address --network-interface-id <ENI_ID> --public-ip <ELASTIC_IP>
```
**Pros**: Direct routing, no additional services needed  
**Cons**: Requires security group modifications, exposes individual task

### Solution 3: Update Domain DNS
If `stream.racetrackstreaming.com` is a custom domain, configure Tailscale DNS to route it to MediaMTX IP
**Pros**: Seamless from RPi perspective  
**Cons**: Requires Tailscale admin access and DNS configuration

### Solution 4: Use Intermediate Relay
Deploy a small EC2 instance with public IP as relay:
- RPi → EC2 (RTSP in on public:8554)
- EC2 → MediaMTX (RTSP out on private:8554)
**Pros**: No AWS console changes, isolated service  
**Cons**: Extra infrastructure, additional latency

### Solution 5: Switch to HLS (Pull Model)
Instead of pushing from RPi, have MediaMTX pull from:
- RPi HTTP server hosting HLS segments
- RPi RTSP server (running locally on RPi, accessible via Tailscale)
**Pros**: No push network issues, MediaMTX initiates connection  
**Cons**: RPi needs additional services, more resource-intensive

## Immediate Action Items

### To Enable Working Stream:
1. **Add ALB Listener** (Solution 1 - recommended):
   ```bash
   # Get MediaMTX target group ARN
   TGROUP_ARN=$(aws elbv2 describe-target-groups \
     --names mediamtx-rtmp \
     --query 'TargetGroups[0].TargetGroupArn' --output text)
   
   ALB_ARN=$(aws elbv2 describe-load-balancers \
     --names broadcast-alb \
     --query 'LoadBalancers[0].LoadBalancerArn' --output text)
   
   # Create TCP listener
   aws elbv2 create-listener \
     --load-balancer-arn $ALB_ARN \
     --protocol TCP \
     --port 8554 \
     --default-actions Type=forward,TargetGroupArn=$TGROUP_ARN
   ```

2. **Verify ALB routing** once listener is created

3. **Verify stream** once connection succeeds:
   ```bash
   curl -s https://stream.racetrackstreaming.com/v1/paths/list | grep rpicam2
   ```

### To Diagnose Further:
```bash
# From RPi, test connectivity
ssh dan7554@100.80.96.23 'ncat -zv broadcast-alb-156701236.us-east-1.elb.amazonaws.com 8554'

# From local, check ALB status
aws elbv2 describe-load-balancers --names broadcast-alb --query 'LoadBalancers[0].[State.Code,DNSName]'

# Check MediaMTX task logs
aws logs tail /ecs/mediamtx --follow --since 5m
```

## Script Status

**Current Script**: `/home/dan7554/rpicam-stream.sh`
```bash
# Targets: rtsp://stream.racetrackstreaming.com:8554/rpicam2
# Uses: named FIFO for rpicam-vid h264 output
# Encoding: h264 passthrough (-c:v copy)
# Service: rpicam-stream.service (auto-restart)
```

**Script is ready to work once network bridge is established.**

## Testing Checklist

Once ALB listener is added:
- [ ] ALB listener shows active on port 8554
- [ ] Target group shows healthy targets for port 8554
- [ ] `ncat -zv <ALB_DNS>:8554` succeeds from RPi
- [ ] ffmpeg connects and stays connected (logs show no "Stream ended" for >30 seconds)
- [ ] MediaMTX logs show "rpicam2: new client" or similar
- [ ] curl to /v1/paths/list shows rpicam2 path
- [ ] HLS playlist is accessible: https://stream.racetrackstreaming.com/hls/rpicam2/index.m3u8
- [ ] Stream playable: `ffplay https://stream.racetrackstreaming.com/hls/rpicam2/index.m3u8`

## Notes for Future Work

1. **Health Checks**: NLB health checks (port 1935) may not be appropriate for RTMP. Consider protocol-specific checks or disabling.

2. **Security**: Exposed ports 1935 (RTMP) and 8554 (RTSP) should have authentication or restricted security groups.

3. **Multi-Camera**: Script/config supports rpicam1, rpicam3 paths - can scale to multiple RPis.

4. **Recording**: MediaMTX is configured to record HLS streams to disk with FMP4 format for each path.

5. **Load Balancing**: Consider sticky sessions if pushing from multiple RPis to ensure consistent target.
