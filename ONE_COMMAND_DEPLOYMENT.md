# 🚀 One-Command Deployment Guide

## Complete Setup in Minutes

Deploy **MediaMTX + Broadcast + ALBs + DNS** with one command.

---

## 🎯 Three Deployment Options

### Option 1: Everything Automated (Recommended)

```bash
make deploy-production
```

**What it does:**
1. Builds and pushes MediaMTX to ECR
2. Deploys MediaMTX ECS cluster + ALB
3. Builds and pushes Broadcast to ECR
4. Deploys Broadcast ECS cluster + ALB
5. Creates Route53 DNS records
6. Sets up Cloudflare (if credentials provided)

**Time:** 15-20 minutes

**Result:** Both services live at their domains with HTTPS

### Option 2: Deploy Infrastructure Only

```bash
make deploy-all
```

**What it does:**
1. Deploy MediaMTX infrastructure
2. Deploy Broadcast infrastructure
3. Create ALBs for both
4. Get DNS names

**Time:** 15 minutes

**Then you:**
- Setup DNS manually in Cloudflare/Route53
- Or use: `make deploy-with-cloudflare`

### Option 3: Deploy + Setup Cloudflare

```bash
# First, set credentials
export CLOUDFLARE_API_TOKEN="your-token"
export CLOUDFLARE_ZONE_ID="your-zone-id"

# Then deploy everything
make deploy-production
```

**What it does:**
1. Everything from deploy-all
2. Automatically creates Cloudflare DNS records
3. Enables SSL/TLS

**Time:** 15-20 minutes (fully automated)

**Result:** Everything live at custom domains with SSL

---

## 📋 Prerequisites

Before running deployment, ensure:

### 1. AWS Configured
```bash
# Verify AWS CLI is configured
aws sts get-caller-identity

# Expected output: Your account ID and ARN
```

### 2. Docker Installed
```bash
docker --version  # Should be 20.10+
```

### 3. Makefile Variables Set (Optional)

In your `.bashrc` or `.zshrc`:
```bash
export AWS_REGION=us-east-2
export AWS_ACCOUNT_ID=123456789012
export DOMAIN_NAME=stream.racetrackstreaming.com
export BROADCAST_DOMAIN=admin.racetrackstreaming.com
```

### 4. Cloudflare Setup (For Automated DNS)
```bash
# Get API token from: https://dash.cloudflare.com/profile/api-tokens
export CLOUDFLARE_API_TOKEN="your-token"

# Get Zone ID from Cloudflare dashboard
export CLOUDFLARE_ZONE_ID="your-zone-id"
```

---

## 🚀 Quick Start (Copy & Paste)

### Step 1: Deploy Everything
```bash
make deploy-production
```

**Output will show:**
```
Phase 1: Building and pushing images to ECR...
Phase 2: Deploying MediaMTX ECS infrastructure...
Phase 3: Building and pushing Broadcast to ECR...
Phase 4: Deploying Broadcast ECS infrastructure...
Phase 5: Creating MediaMTX ALB...
Phase 6: Creating Broadcast ALB...
Phase 7: Getting DNS information...

✅ DEPLOYMENT COMPLETE!

🎬 BROADCAST ADMIN:
   Domain: https://admin.racetrackstreaming.com

📡 MEDIAMTX STREAMING:
   Domain: https://stream.racetrackstreaming.com:8888
   RTSP: rtsp://stream.racetrackstreaming.com:8554/rpicam2
```

### Step 2: Test Services
```bash
# Test Broadcast
curl https://admin.racetrackstreaming.com/health

# Test MediaMTX
curl http://stream.racetrackstreaming.com:8888/

# Or open in browser
https://admin.racetrackstreaming.com
```

### Step 3: Monitor
```bash
# Watch Broadcast logs
make broadcast-aws-logs

# Watch MediaMTX logs
make ecs-logs

# Check status
make broadcast-aws-status
make ecs-status
```

---

## 🎬 What Gets Deployed

### Infrastructure Created:

```
AWS Account
├── ECR Repositories
│   ├── mediamtx
│   └── broadcast-system
│
├── ECS Clusters
│   ├── mediamtx-cluster
│   │   ├── Service: mediamtx-service
│   │   ├── Tasks: 1+ instances
│   │   └── Logs: /ecs/mediamtx
│   │
│   └── broadcast-cluster
│       ├── Service: broadcast-service
│       ├── Tasks: 1+ instances
│       └── Logs: /ecs/broadcast
│
├── Application Load Balancers
│   ├── mediamtx-alb
│   │   ├── Target Group: mediamtx-tg (port 8888)
│   │   ├── Listener: HTTP 80 → HTTPS 443
│   │   └── DNS: mediamtx-alb-xxx.us-east-2.elb.amazonaws.com
│   │
│   └── broadcast-alb
│       ├── Target Group: broadcast-tg (port 3001)
│       ├── Listener: HTTP 80 → HTTPS 443
│       └── DNS: broadcast-alb-xxx.us-east-2.elb.amazonaws.com
│
├── Security Groups
│   ├── mediamtx-security-group (ports 8554, 8888, 8889, 1935, 9996)
│   └── broadcast-sg (port 3001)
│
└── DNS (Cloudflare or Route53)
    ├── admin.racetrackstreaming.com → Broadcast ALB
    ├── stream.racetrackstreaming.com → MediaMTX ALB
    └── rtsp.racetrackstreaming.com → MediaMTX ALB
```

### Services Available:

| Service | URL | Type | Port |
|---------|-----|------|------|
| Broadcast Admin | https://admin.racetrackstreaming.com | HTTPS | 443 |
| MediaMTX Web | https://stream.racetrackstreaming.com:8888 | HTTPS | 8888 |
| MediaMTX RTSP | rtsp://stream.racetrackstreaming.com:8554 | RTSP | 8554 |
| MediaMTX WebRTC | https://stream.racetrackstreaming.com:8889 | HTTPS | 8889 |

---

## 📊 Deployment Phases Explained

### Phase 1: Build & Push MediaMTX (2 minutes)
```
✓ Build MediaMTX Docker image
✓ Login to AWS ECR
✓ Tag image for ECR
✓ Push to ECR repository
```

### Phase 2: Deploy MediaMTX ECS (3 minutes)
```
✓ Create IAM execution role
✓ Create ECS cluster
✓ Create CloudWatch logs
✓ Create security groups
✓ Register task definition
✓ Create ECS service
✓ Wait for tasks to start
```

### Phase 3: Build & Push Broadcast (2 minutes)
```
✓ Build Broadcast Docker image
✓ Push to ECR repository
```

### Phase 4: Deploy Broadcast ECS (3 minutes)
```
✓ Create IAM execution role
✓ Create ECS cluster
✓ Create CloudWatch logs
✓ Register task definition
✓ Create ECS service
✓ Wait for tasks to start
```

### Phase 5: Create MediaMTX ALB (2 minutes)
```
✓ Create target group (port 8888)
✓ Create load balancer
✓ Create listeners (HTTP 80, HTTPS 443)
✓ Connect service to ALB
```

### Phase 6: Create Broadcast ALB (2 minutes)
```
✓ Create target group (port 3001)
✓ Create load balancer
✓ Create listeners (HTTP 80, HTTPS 443)
✓ Connect service to ALB
```

### Phase 7: DNS Setup (1-5 minutes)
```
✓ Get ALB DNS names
✓ Create Route53 A records (or)
✓ Create Cloudflare DNS records
✓ Enable SSL/TLS
```

---

## ✅ Success Verification

After deployment completes, verify everything works:

```bash
# 1. Check Broadcast is running
make broadcast-aws-status
# Expected: Running 1, Desired 1, Status ACTIVE

# 2. Check MediaMTX is running
make ecs-status
# Expected: Running 1, Desired 1, Status ACTIVE

# 3. Test Broadcast health
curl https://admin.racetrackstreaming.com/health
# Expected: {"status": "ok"}

# 4. Test MediaMTX health
curl http://stream.racetrackstreaming.com:8888
# Expected: HTTP 200 OK

# 5. Check DNS resolution
dig admin.racetrackstreaming.com
dig stream.racetrackstreaming.com
# Expected: Shows IP addresses

# 6. Verify SSL certificate
curl -v https://admin.racetrackstreaming.com
# Expected: Certificate from Cloudflare or AWS
```

---

## 🔧 Troubleshooting

### Deployment Gets Stuck

```bash
# Check what phase failed
tail -50 /tmp/deployment.log  # If you redirected output

# Or check services individually
make ecs-status
make broadcast-aws-status

# View logs
make ecs-logs | grep ERROR
make broadcast-aws-logs | grep ERROR
```

### Task Won't Start

```bash
# Check task definition
aws ecs describe-task-definition --task-definition mediamtx-task

# Check service events
aws ecs describe-services --cluster mediamtx-cluster --services mediamtx-service

# View logs
make ecs-logs
```

### ALB Not Responding

```bash
# Check target health
aws elbv2 describe-target-health --target-group-arn <ARN>

# Check security groups
aws ec2 describe-security-groups --group-ids sg-xxxxx

# Restart service
make ecs-update
make broadcast-aws-update
```

### DNS Not Working

```bash
# Check DNS resolution
dig admin.racetrackstreaming.com

# Check Cloudflare records
curl https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/dns_records \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"

# Manually update Cloudflare
make cloudflare-update-dns
```

---

## 📈 Cost Estimate

After deployment, costs are:

| Component | Monthly Cost |
|-----------|-------------|
| MediaMTX ALB | ~$28 |
| Broadcast ALB | ~$28 |
| MediaMTX ECS (1 task) | ~$9 |
| Broadcast ECS (1 task) | ~$9 |
| ECR Storage | ~$0.50 |
| CloudWatch Logs | ~$5 |
| Route53 | ~$0.50 |
| **TOTAL** | **~$80/month** |

**To reduce costs:**
```bash
# Stop compute (saves ~$18)
make aws-stop-services

# Delete ALBs (saves ~$56)
make alb-cleanup
make broadcast-alb-cleanup

# Delete everything (saves ~$80)
make aws-cleanup-all
```

---

## 🔄 Updating Services

### Quick Update (After Code Changes)

```bash
make quick-deploy-all
```

**What it does:**
1. Rebuild MediaMTX image
2. Push to ECR
3. Update ECS service
4. Rebuild Broadcast image
5. Push to ECR
6. Update Broadcast service

**Time:** ~5 minutes

### Update Just MediaMTX

```bash
make ecr-push
make ecs-update
```

### Update Just Broadcast

```bash
make broadcast-aws-push
make broadcast-aws-update
```

---

## 📝 Advanced Usage

### Custom Configuration

Override default settings:

```bash
# Different region
make deploy-all AWS_REGION=us-west-2

# Different domain
make deploy-all DOMAIN_NAME=mystream.example.com

# Custom cluster names
make deploy-all ECS_CLUSTER_NAME=my-cluster

# Specific image versions
make deploy-all IMAGE_VERSION=v1.2.3
```

### Scale to Multiple Tasks

```bash
# Update desired count
aws ecs update-service \
  --cluster mediamtx-cluster \
  --service mediamtx-service \
  --desired-count 3

# ALB will automatically load balance
```

### Enable Additional Monitoring

```bash
# Create CloudWatch alarms
aws cloudwatch put-metric-alarm \
  --alarm-name mediamtx-cpu-high \
  --alarm-description "Alert when CPU > 80%" \
  --metric-name CPUUtilization \
  --namespace AWS/ECS \
  --statistic Average \
  --period 300 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold
```

---

## 📞 Getting Help

### See All Available Commands

```bash
# All deployment commands
grep "^deploy" Makefile | grep "##"

# All ALB commands
grep "alb" Makefile | grep "##"

# All AWS commands
grep "aws\|ecs\|ecr" Makefile | grep "##"
```

### Check Documentation

```bash
# Broadcast ALB
cat BROADCAST_ALB_DEPLOYMENT.md

# MediaMTX ALB
cat BROADCAST_ALB_DEPLOYMENT.md  # Same guide works for both

# Architecture
cat ARCHITECTURE_TROUBLESHOOTING.md

# Commands
cat AWS_DEPLOYMENT_COMMANDS.md
```

### Common Commands

```bash
# Monitor
make broadcast-aws-logs
make ecs-logs
make broadcast-aws-status
make ecs-status

# Update
make quick-deploy-all

# Troubleshoot
make dns-check
make aws-list-resources
make aws-cost-estimate

# Cleanup
make aws-cleanup-all
```

---

## 🎓 Understanding the Workflow

### Request Flow

```
User Browser
    ↓
Cloudflare (DNS + SSL)
    ↓
ALB (Load Balancer)
    ├─→ Broadcast ALB → Broadcast Task (port 3001)
    └─→ MediaMTX ALB → MediaMTX Task (port 8888/8554/8889)
    ↓
Response to User
```

### Data Flow During Setup

```
make deploy-production
├─ Builds images locally
├─ Pushes to ECR (AWS image registry)
├─ Creates ECS clusters
├─ Deploys containers to ECS
├─ Creates ALBs (load balancers)
├─ Registers tasks with ALBs
├─ Creates DNS records
└─ Configures Cloudflare
```

---

## ✨ Next Steps After Deployment

### 1. Monitor Services
```bash
watch -n 2 'make ecs-status && make broadcast-aws-status'
```

### 2. Configure Alerts
```bash
# Set up CloudWatch alarms
# Monitor CPU, memory, error rates
```

### 3. Enable Auto-Scaling
```bash
# Scale to 2-3 tasks for high availability
make ecs-update
```

### 4. Setup Backups
```bash
# Configure CloudWatch logs retention
# Export logs to S3
```

### 5. Plan Updates
```bash
# Setup CI/CD pipeline
# Automate image builds
# Implement blue-green deployments
```

---

## 🎯 Commands Summary

| Command | Purpose | Time |
|---------|---------|------|
| `make deploy-production` | Everything (fully automated) | 15-20 min |
| `make deploy-all` | Infrastructure only | 15 min |
| `make deploy-with-cloudflare` | Automated DNS setup | 2 min |
| `make quick-deploy-all` | Update both services | 5 min |
| `make broadcast-aws-logs` | Watch Broadcast logs | - |
| `make ecs-logs` | Watch MediaMTX logs | - |
| `make broadcast-aws-status` | Check Broadcast status | - |
| `make ecs-status` | Check MediaMTX status | - |
| `make aws-cost-estimate` | Show estimated costs | - |
| `make aws-cleanup-all` | Delete everything | 5 min |

---

## 🚀 You're Ready!

Everything is set up for production deployment. 

**Start now:**
```bash
make deploy-production
```

**Then monitor:**
```bash
make broadcast-aws-logs
make ecs-logs
```

**Access your services:**
- https://admin.racetrackstreaming.com
- https://stream.racetrackstreaming.com:8888

Good luck! 🎉
