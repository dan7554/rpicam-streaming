# EC2 Deployment Quick Reference

**Status**: ✅ Production Ready  
**Last Updated**: December 22, 2025

---

## 🚀 Quick Start (Choose One)

### Option 1: Fresh Deployment (Recommended)
```bash
# Deploy entire stack to EC2
make deploy

# Check status
make status

# Monitor logs
make logs
```

### Option 2: Step-by-Step Setup
```bash
# Initialize everything
make setup

# Then manage with
make status
make logs
make update
```

---

## 📋 Common Commands

| Command | Purpose | Status |
|---------|---------|--------|
| `make deploy` | Deploy EC2 stack | ✅ Primary |
| `make setup` | Initialize EC2 setup | ✅ Primary |
| `make update` | Update services | ✅ Primary |
| `make quick` | Quick rebuild & push | ✅ Primary |
| `make status` | Check deployment | ✅ Always use |
| `make logs` | View real-time logs | ✅ Always use |
| `make deploy-fargate` | Deploy to Fargate | ⚠️ Legacy |
| `make setup-fargate` | Initialize Fargate | ⚠️ Legacy |

---

## 🔧 Infrastructure Commands

### EC2 Instance Management
```bash
# Launch new EC2 instance
make mediamtx-ec2-launch

# Register instances with ECS
make mediamtx-ec2-register-instances

# View instance status
make status
```

### Service Management
```bash
# Create/update task definitions
make mediamtx-ec2-task-def

# Create/update service
make mediamtx-ec2-service

# Full deployment
make mediamtx-ec2-deploy
```

### Image Management
```bash
# Build Docker image
make mediamtx-build

# Push to ECR
make mediamtx-ecr-push

# Update with latest image
make mediamtx-update-ec2
```

---

## 🌐 Network & Access

```bash
# Show DNS configuration
make dns-info

# Check domain accessibility
make dns-check

# Request SSL certificate
make ssl-request-cert

# Validate DNS for SSL
make ssl-validate-dns

# Create HTTPS listener
make ssl-create-https-listener

# Redirect HTTP → HTTPS
make ssl-update-alb
```

---

## 📊 Monitoring & Logs

```bash
# Check deployment status
make status

# Stream logs (real-time)
make logs

# Show environment variables
make debug-env

# View EC2 instance health
aws ecs describe-services \
  --cluster broadcast-cluster \
  --services mediamtx-service-ec2 \
  --region us-east-1 \
  --query 'services[0]'
```

---

## 🔍 Troubleshooting

### Check if EC2 instances registered
```bash
aws ecs list-container-instances \
  --cluster broadcast-cluster \
  --region us-east-1
```

### View running tasks
```bash
aws ecs list-tasks \
  --cluster broadcast-cluster \
  --service-name mediamtx-service-ec2 \
  --region us-east-1
```

### View task logs
```bash
aws logs tail /ecs/mediamtx --follow --region us-east-1
```

### Check EC2 instance details
```bash
aws ec2 describe-instances \
  --filters "Name=tag:Service,Values=mediamtx" \
  --region us-east-1
```

### Test RTSP endpoint
```bash
# Direct RTSP
ffplay 'rtsp://broadcast-nlb-....elb.us-east-1.amazonaws.com:8554/rpicam2'

# Via VLC
open 'rtsp://broadcast-nlb-....elb.us-east-1.amazonaws.com:8554/rpicam2'
```

### Test HLS endpoint
```bash
# Direct HTTP
curl http://broadcast-nlb-....elb.us-east-1.amazonaws.com:8888/hls/rpicam2/index.m3u8

# Via browser (when firewall allows)
# http://broadcast-nlb-....elb.us-east-1.amazonaws.com:8888/hls/rpicam2/index.m3u8
```

---

## 🛑 Cleanup & Removal

### Stop EC2 service
```bash
aws ecs update-service \
  --cluster broadcast-cluster \
  --service mediamtx-service-ec2 \
  --desired-count 0 \
  --region us-east-1
```

### Terminate EC2 instances
```bash
aws ec2 terminate-instances \
  --instance-ids i-xxxxx i-yyyyy \
  --region us-east-1
```

### Delete Fargate services (if migrating)
```bash
aws ecs delete-service \
  --cluster broadcast-cluster \
  --service mediamtx-service \
  --force \
  --region us-east-1
```

### Delete everything
```bash
make cleanup-all
```

---

## 📱 Stream Access

### When Firewall Allows Direct Access

```bash
# RTSP (for VLC, ffplay)
rtsp://broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com:8554/rpicam2

# HLS (for browsers)
http://broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com:8888/hls/rpicam2/index.m3u8

# RTMP (for OBS, YouTube)
rtmp://broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com:1935/rpicam2
```

### Via CloudFlare Tunnel

```bash
# Admin Dashboard
https://admin.racetrackstreaming.com

# Streaming
https://stream.racetrackstreaming.com/hls/rpicam2/index.m3u8
```

---

## ✅ Deployment Checklist

- [ ] Run `make deploy`
- [ ] Run `make status` - verify 2/2 or more tasks running
- [ ] Run `make logs` - check for errors
- [ ] Test RTSP: `ffplay 'rtsp://...:8554/rpicam2'`
- [ ] Test HLS: `curl http://...:8888/hls/rpicam2/index.m3u8`
- [ ] Update RPi stream host (if needed)
- [ ] Configure CloudFlare DNS (if using tunnel)
- [ ] Check admin dashboard: `https://admin.racetrackstreaming.com`

---

## 🆘 Need Help?

### View all available targets
```bash
make help
```

### Show environment & config
```bash
make debug-env
```

### Check Makefile syntax
```bash
make -n deploy  # Dry run - shows what would execute
```

### AWS CLI Troubleshooting
```bash
# Verify AWS credentials
aws sts get-caller-identity

# Check ECS cluster
aws ecs describe-clusters --cluster-names broadcast-cluster --region us-east-1

# List all services
aws ecs list-services --cluster broadcast-cluster --region us-east-1
```

---

## 🎯 Key Differences: EC2 vs Fargate

| Aspect | EC2 | Fargate |
|--------|-----|--------|
| **HTTP Endpoints** | ✅ Works | ❌ Timeouts |
| **HLS Streaming** | ✅ Works | ❌ Timeouts |
| **WebRTC** | ✅ Works | ❌ Timeouts |
| **RTSP Input** | ✅ Works | ✅ Works |
| **Cost** | $0.02/hr | $0.05-0.10/hr |
| **Scaling** | Manual + Launch Config | Auto via Fargate |
| **Networking** | Bridge Mode | ENI (awsvpc) |

**Recommendation**: Use EC2 for this use case. Fargate's HTTP timeout issue makes it unsuitable for HLS/WebRTC streaming.

---

**Last Updated**: December 22, 2025  
**Makefile Version**: 1.0 EC2-Primary  
**Created By**: Migration from Fargate → EC2 solution
