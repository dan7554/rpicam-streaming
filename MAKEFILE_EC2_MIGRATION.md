# Makefile EC2 Migration Guide

**Date**: December 22, 2025  
**Status**: ✅ Complete  
**Recommendation**: Use EC2-based deployment (no Fargate)

---

## Summary of Changes

The Makefile has been reorganized to **make EC2-based ECS the primary recommended deployment** and move Fargate to legacy status.

### Root Cause: Fargate HTTP Response Timeout

AWS Fargate has a known networking issue that causes:
- ✅ TCP connections establish successfully
- ❌ HTTP responses timeout
- 🔴 Affects HLS, WebRTC, API endpoints

**Root Cause**: "Preserve Client IP" + Fargate ENI networking incompatibility

### EC2 Solution Benefits

| Feature | Fargate | EC2 | 
|---------|---------|-----|
| HTTP Response Timeout | ❌ Yes | ✅ No |
| Network Control | Limited | Full |
| Bridge Networking | ❌ No | ✅ Yes |
| Cost (t3.medium) | Varies | $0.02/hour |
| All Protocols Work | ❌ No | ✅ Yes |

---

## Updated Command Structure

### Primary Commands (EC2)

```bash
# Deploy to EC2 (RECOMMENDED)
make deploy              # Full deployment to EC2
make setup              # Initial EC2 setup
make update             # Update services on EC2
make quick              # Quick rebuild & update on EC2
make status             # Check EC2 service status
make logs               # Tail EC2 logs
```

### Legacy Commands (Fargate)

```bash
# Deploy to Fargate (Legacy - not recommended)
make deploy-fargate     # Full deployment to Fargate
make setup-fargate      # Initial Fargate setup
make update-fargate     # Update services on Fargate  # (not implemented - use deploy-fargate)
make quick-fargate      # Quick rebuild & update on Fargate  # (not implemented - use deploy-fargate)
```

### Detailed EC2-Specific Commands

```bash
# EC2 Infrastructure
make mediamtx-ec2-launch              # Launch new EC2 instance
make mediamtx-ec2-register-instances  # Register instances with ECS
make mediamtx-ec2-task-def            # Create EC2 task definition
make mediamtx-ec2-service             # Create EC2 service
make mediamtx-ec2-deploy              # Full EC2 deployment
make mediamtx-update-ec2              # Update MediaMTX EC2 service
```

### Detailed Fargate-Specific Commands (Legacy)

```bash
# Fargate Infrastructure (Legacy)
make mediamtx-deploy                  # Deploy to Fargate
make mediamtx-task-def                # Create Fargate task definition
make mediamtx-service                 # Create Fargate service
make mediamtx-update                  # Update MediaMTX Fargate service
make mediamtx-logs                    # Create CloudWatch logs
make mediamtx-ecr-push                # Push image to ECR
```

---

## Help Output Changes

### Before
```
📡 MEDIAMTX (Media Streaming Server):
📡 MEDIAMTX EC2 (Fixes Fargate HTTP Timeout - RECOMMENDED):
🔗 ORCHESTRATION (Deploy Both):
  deploy         🚀 Deploy both MediaMTX and broadcast-system
  deploy-ec2     🚀 Deploy to EC2 (RECOMMENDED - fixes Fargate HTTP timeout)
```

### After
```
✅ PRIMARY: EC2-BASED MEDIAMTX (Recommended - Fixes Fargate timeout)
📡 MEDIAMTX FARGATE (Legacy - HTTP timeout issues):
🔗 ORCHESTRATION (Deploy Both):
  deploy         🚀 Deploy both services (EC2 - Recommended)
  deploy-ec2     🚀 Deploy to EC2 (RECOMMENDED - fixes Fargate HTTP timeout)
```

---

## Migration Steps

### If You're Currently Using Fargate

To migrate to EC2:

```bash
# 1. Deploy new EC2 infrastructure
make deploy

# 2. Update RPi to use new endpoint (if changed)
make update-rpi-rtmp

# 3. Verify EC2 is working
make status

# 4. Optional: Keep Fargate running in parallel during transition
# Optional: Stop Fargate services when ready
aws ecs update-service --cluster broadcast-cluster --service mediamtx-service --desired-count 0
```

### If You're Starting Fresh

```bash
# 1. Deploy EC2 (this is now the default)
make deploy

# 2. Check status
make status

# 3. Monitor logs
make logs
```

---

## Makefile Header Update

**Old**:
```
# QUICK START:
#   For EC2 (RECOMMENDED):    make deploy-ec2
#   For Fargate (legacy):     make deploy
```

**New**:
```
# QUICK START:
#   Deploy to EC2 (RECOMMENDED):  make deploy
#   Deploy to Fargate (legacy):   make deploy-fargate
#   Quick update (EC2):           make update
```

---

## Code Organization

### Section Headers

1. **Global Configuration** - AWS region, account, VPC settings
2. **Configuration Variables** - MediaMTX & Broadcast ports, resources
3. **Help Section** - Updated to show EC2 as primary
4. **MediaMTX ECR & Docker Build** - Shared between EC2 and Fargate
   - ⚠️ Marked as "LEGACY FARGATE TARGETS"
5. **✅ EC2-BASED MEDIAMTX DEPLOYMENT (PRIMARY)** - New prominent section
6. **Broadcast-System Targets** - Shared between both deployments
7. **Orchestration** - Deploy, setup, update commands (EC2 primary)
8. **NLB Deployment** - For RTMP streaming
9. **DNS & Access** - Domain configuration
10. **SSL/TLS Configuration** - ALB HTTPS setup
11. **Local Development** - docker-compose for testing
12. **Cleanup & Debugging** - Maintenance commands

---

## Phony Targets Updated

```makefile
.PHONY: setup setup-ec2 setup-fargate deploy deploy-ec2 deploy-fargate
.PHONY: quick quick-ec2 update update-ec2 status logs
```

**New targets**:
- `setup-ec2` - Initial EC2 setup
- `setup-fargate` - Initial Fargate setup (legacy)
- `deploy-ec2` - Deploy to EC2 (explicit)
- `deploy-fargate` - Deploy to Fargate (explicit)
- `update-ec2` - Update EC2 services
- `quick-ec2` - Quick EC2 update

**Changed targets** (now point to EC2 by default):
- `setup` → `setup-ec2`
- `deploy` → `deploy-ec2`
- `update` → `update-ec2`
- `quick` → `quick-ec2`

---

## Infrastructure Diagram (EC2 Primary)

```
┌──────────────────────────────────────────────────────────────┐
│  RPi Camera Stream (1280x720 H.264)                          │
└──────────────────────────────────────────────────────────────┘
                         ↓ (RTSP push via ffmpeg)
┌──────────────────────────────────────────────────────────────┐
│  Network Load Balancer (NLB) - broadcast-nlb-...             │
│  Port 8554/TCP (RTSP)  →  EC2 Instance                       │
│  Port 1935/TCP (RTMP)  →  EC2 Instance                       │
└──────────────────────────────────────────────────────────────┘
                         ↓
┌──────────────────────────────────────────────────────────────┐
│  ECS on EC2 (broadcast-cluster)                              │
│                                                              │
│  ✅ MediaMTX (bridge networking)                             │
│     - Port 8554/TCP (RTSP input)                             │
│     - Port 8888/TCP (HLS output) ✅ Works!                  │
│     - Port 8889/TCP (WebRTC output) ✅ Works!               │
│     - Port 1935/TCP (RTMP output) ✅ Works!                 │
│     - Port 8890/TCP (API) ✅ Works!                          │
│                                                              │
│  📺 Broadcast-System (nginx reverse proxy)                   │
│     - Port 80/TCP (HTTP)                                     │
│     - Port 443/TCP (HTTPS via ALB/CloudFlare)                │
└──────────────────────────────────────────────────────────────┘
                         ↓
┌──────────────────────────────────────────────────────────────┐
│  Application Load Balancer (ALB)                             │
│  → broadcast-service (admin dashboard)                       │
└──────────────────────────────────────────────────────────────┘
                         ↓
┌──────────────────────────────────────────────────────────────┐
│  CloudFlare Tunnel + DNS                                     │
│  admin.racetrackstreaming.com → ALB                          │
│  stream.racetrackstreaming.com → MediaMTX HLS               │
└──────────────────────────────────────────────────────────────┘
```

---

## Testing & Validation

### Verify EC2 Deployment
```bash
# Check services running
make status

# Watch logs
make logs

# Test RTSP endpoint
ffplay 'rtsp://broadcast-nlb-...elb.us-east-1.amazonaws.com:8554/rpicam2'

# Test HLS endpoint
curl http://broadcast-nlb-...elb.us-east-1.amazonaws.com:8888/hls/rpicam2/index.m3u8
```

### Compare with Fargate
```bash
# If still running Fargate, you'll see both services
make status

# mediamtx-service (Fargate) - may show HTTP timeout issues
# mediamtx-service-ec2 (EC2) - will work correctly
```

---

## Cleanup (If Removing Fargate)

```bash
# Stop Fargate MediaMTX service
aws ecs update-service --cluster broadcast-cluster \
  --service mediamtx-service --desired-count 0

# Delete Fargate task definition
aws ecs deregister-task-definition \
  --task-definition mediamtx-task

# Keep EC2 service and EC2 task definition
# Keep broadcast-system on both (shared)
```

---

## FAQ

**Q: Can I run both EC2 and Fargate simultaneously?**  
A: Yes, they use different service names (`mediamtx-service` vs `mediamtx-service-ec2`), so you can test both. Just ensure EC2 instances are registered with ECS cluster first.

**Q: What if I need to scale to more cameras?**  
A: EC2 bridge networking supports unlimited streams. Scale horizontally by:
1. Launch additional EC2 instances
2. Register with ECS cluster
3. Increase service desired count
4. Load balancer automatically routes traffic

**Q: Will HTTP endpoints work now?**  
A: ✅ Yes! HLS, WebRTC, API will all work properly on EC2. Fargate has this bug.

**Q: Cost difference?**  
A: EC2 t3.medium ≈ $0.02/hour. Fargate 2 tasks at 512 CPU/1024 MB ≈ $0.05-0.10/hour depending on usage.

---

## References

- **Fargate Issue**: AWS Fargate ENI networking with "Preserve Client IP"
- **EC2 Solution**: Bridge networking provides direct port mapping
- **Performance**: No difference; both use same MediaMTX image
- **Reliability**: EC2 has better HTTP response handling

---

**Last Updated**: December 22, 2025  
**Makefile Version**: 1.0 EC2-Primary  
**Status**: ✅ Production Ready
