# Media-MTX Broadcast System - Complete Deployment Guide

## Quick Start

```bash
# See all deployment options
make deploy-all

# Deploy everything (recommended - Fargate)
make deploy

# Check status
make status
```

---

## Architecture Overview

### Deployment Platform: AWS Fargate

All services run on **AWS Fargate** - a fully managed container orchestration platform with no EC2 instances to manage.

### Components

**MediaMTX (Streaming Server)**
- RTSP input from cameras (port 8554)
- Outputs: RTMP (1935), HLS (8888), WebRTC (8889), SRT (8891)
- API: Port 8890 (control) + 9997 (local queries)
- Health check: HTTP GET on port 8888 (HLS endpoint)
- **Deployment: 2 tasks on Fargate**

**Broadcast-System (Admin Dashboard)**
- Web UI for configuration and control
- Port 80/443 via ALB
- Connects to MediaMTX for configuration
- Health check: HTTP GET /health
- **Deployment: 1 task on Fargate**

**Load Balancing**
- ALB (Application Load Balancer) for Broadcast (port 80/443)
- NLB (Network Load Balancer) for RTMP (port 1935) - Optional
- Target groups with automatic health monitoring

---

## Deployment Options

### Standard Deployment (Recommended)
```bash
make deploy
```
- Deploys both MediaMTX + Broadcast to Fargate
- Error-tolerant update strategy
- Automatically creates task definitions + services
- Good for most use cases

**Pros:** Simple, fully managed, scales automatically, no EC2 to manage
**Cons:** None for typical streaming scenarios

---

### Initial Setup (First Time Only)
```bash
make setup
```
For fresh deployments with full infrastructure provisioning.

---

## Deployment Commands

### Deploy/Update
| Command | Purpose |
|---------|---------|
| `make deploy` | Deploy everything to Fargate (recommended) |
| `make setup` | Initial setup with infrastructure |
| `make update` | Update services with latest images |
| `make quick` | Fast update (skips some checks) |

### Status & Monitoring
| Command | Purpose |
|---------|---------|
| `make status` | Show running tasks + ALB info |
| `make logs` | Tail real-time logs from both services |
| `make debug-env` | Display all configuration settings |

### Cleanup
| Command | Purpose |
|---------|---------|
| `make cleanup` | Delete services (keep images + logs) |
| `make cleanup-all` | Full cleanup (delete everything) |

---

## DNS & HTTPS Setup

### View DNS Configuration
```bash
make dns-info
```
Shows ALB DNS name and required CNAME records for Cloudflare.

### Test Domain Accessibility
```bash
make dns-check
```

### Enable HTTPS (Optional)
```bash
make ssl-setup                 # Request certificate
make ssl-create-https-listener # Enable HTTPS on ALB
make ssl-update-alb            # HTTP → HTTPS redirect
```

---

## RTMP Load Balancing (Optional)

For high-volume RTMP broadcasting to YouTube:

```bash
make nlb-deploy      # Create NLB
make nlb-status      # Check health
make update-rpi-rtmp # Update RPi to use NLB
```

---

## Legacy Shell Scripts

The following scripts are in the root directory but **should use Makefile targets instead**:

| Script | Use Instead | Purpose |
|--------|-------------|---------|
| `cleanup.sh` | `make cleanup-all` | Full cleanup |
| `launch-ec2-fresh.sh` | Reference only | EC2 setup (not recommended) |
| `e2e-test-fargate.sh` | Reference | Fargate testing reference |
| `configure-ec2-ecs.sh` | Reference only | EC2 config (not recommended) |
| `register-nlb-targets.sh` | `make nlb-register` | NLB target registration |
| `diagnose-nlb.sh` | Reference | NLB debugging reference |
| `fix-health-checks.sh` | `make fix-broadcast-service` | ALB health checks |

**Note:** EC2-related scripts are kept for reference only. Stick with **Fargate deployment** for simplicity and cost-effectiveness.

---

## Makefile Targets Summary

### Service Deployment
- `mediamtx-service` - Create MediaMTX Fargate service
- `mediamtx-deploy` - Complete MediaMTX deployment
- `broadcast-deploy` - Complete broadcast deployment
- `fix-broadcast-service` - Fix ALB + broadcast configuration

### Infrastructure
- `mediamtx-logs` - Create CloudWatch log group
- `broadcast-logs` - Create CloudWatch log group
- `mediamtx-task-def` - Register task definition
- `broadcast-task-def` - Register task definition

### Build & Registry
- `mediamtx-build` - Build Docker image
- `broadcast-build` - Build Docker image
- `mediamtx-ecr-push` - Push to ECR
- `broadcast-ecr-push` - Push to ECR

### EC2 Specific
- `mediamtx-ec2-launch` - Launch EC2 instance
- `mediamtx-ec2-register-instances` - Register with ECS
- `mediamtx-deploy-ec2` - Deploy to EC2

### Orchestration
- `deploy` - Full standard deployment
- `deploy-ec2` - Full EC2 deployment
- `deploy-fargate` - Full Fargate deployment
- `setup` - Initial setup (creates infrastructure)
- `update` - Update services
- `status` - Show running status
- `logs` - Tail logs

### DNS & SSL
- `dns-info` - Show DNS configuration
- `dns-check` - Test domains
- `ssl-setup` - SSL/TLS setup
- `ssl-create-https-listener` - Enable HTTPS

### NLB (RTMP)
- `nlb-deploy` - Create + register NLB
- `nlb-status` - Check NLB health
- `update-rpi-rtmp` - Update RPi for NLB

### Cleanup
- `cleanup` - Delete services only
- `cleanup-all` - Delete everything

---

## Configuration

Key variables in Makefile:
```bash
AWS_REGION              = us-east-1
ECS_CLUSTER             = broadcast-cluster
MEDIAMTX_SERVICE        = mediamtx-service
BROADCAST_SERVICE       = broadcast-service
ADMIN_DOMAIN            = admin.racetrackstreaming.com
STREAM_DOMAIN           = stream.racetrackstreaming.com
```

View all configuration:
```bash
make debug-env
```

---

## Troubleshooting

### Services not starting
```bash
make status  # Check running count
make logs    # Check logs for errors
```

### HTTP endpoints timing out
This is a Fargate issue. Switch to EC2:
```bash
make cleanup-all
make setup-ec2
make deploy-ec2
```

### Services stuck in DRAINING
Wait ~60 seconds, then deploy again. Services need time to fully cleanup.

### Missing domains
Run `make dns-info` and add CNAME records to Cloudflare.

### Health checks failing
```bash
make fix-broadcast-service  # Fix ALB configuration
make status                 # Verify health
```

---

## Environment Details

**Current Deployment:**
- Cluster: broadcast-cluster (Fargate)
- Region: us-east-1
- VPC: vpc-070fc6caa87f0f18d
- Subnet: subnet-0f1c0059915c44410
- Security Group: sg-084ba18877836077a

**Services:**
- MediaMTX: 2 tasks (0.5 vCPU, 1 GB RAM each)
- Broadcast: 1 task (0.25 vCPU, 512 MB RAM)

**Storage:**
- ECR repositories: mediamtx, broadcast-system
- CloudWatch logs: /ecs/mediamtx, /ecs/broadcast
- Task definitions: mediamtx-task, broadcast-task

---

## Quick Reference

```bash
# First time
make setup               # Full setup with infrastructure

# Deploy
make deploy             # Deploy everything to Fargate
make update             # Update services

# Monitor
make status             # Check status
make logs               # Watch logs

# Cleanup
make cleanup-all        # Delete everything and start fresh

# Show all options
make deploy-all         # Display full deployment guide
```

---

## Further Reading

- [AWS ECS Documentation](https://docs.aws.amazon.com/ecs/)
- [MediaMTX Documentation](https://github.com/bluenviron/mediamtx)
- [broadcast-system README](broadcast-system/README.md)

