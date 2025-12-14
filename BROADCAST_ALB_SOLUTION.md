# 🚀 Broadcast ALB Deployment - Complete Solution

## What Was Added

I've added comprehensive Broadcast System ALB (Application Load Balancer) support to your MediaMTX project. This enables production-grade domain-based access to your Broadcast system at `admin.racetrackstreaming.com`.

### Files Added

1. **BROADCAST_ALB_DEPLOYMENT.md** (Complete ALB Setup Guide)
   - Step-by-step deployment instructions
   - Configuration details
   - Troubleshooting guide
   - Monitoring and maintenance

2. **AWS_DEPLOYMENT_COMMANDS.md** (Command Reference)
   - All deployment commands organized by system
   - Quick-start workflows
   - Cost management
   - Production pipeline examples

3. **ARCHITECTURE_TROUBLESHOOTING.md** (Architecture & Debugging)
   - Visual architecture diagrams
   - Request flow explanations
   - Health check details
   - Decision trees for troubleshooting
   - Emergency procedures

### Makefile Updates

Added 9 new Broadcast ALB targets to your Makefile:

```makefile
# Broadcast ALB Targets (NEW)
make broadcast-alb-create              # Create ALB infrastructure
make broadcast-alb-create-target-group # Create target group
make broadcast-alb-create-alb          # Create load balancer
make broadcast-alb-create-listener     # Create HTTP/HTTPS listeners
make broadcast-alb-update-service      # Connect service to ALB
make broadcast-alb-get-dns             # Get ALB DNS name
make broadcast-alb-cleanup             # Delete ALB
make broadcast-alb-info                # Show configuration info
```

---

## 🎯 Quick Start (5 minutes)

### 1. Deploy Broadcast System to ECS

```bash
make broadcast-aws-deploy
```

This creates:
- ECS cluster
- Task definition
- ECS service
- CloudWatch logs
- IAM roles

### 2. Create ALB

```bash
make broadcast-alb-create
```

This creates:
- Target group (port 3001)
- Application Load Balancer
- Security group with rules
- HTTP listener (auto-redirect to HTTPS)

### 3. Connect Service to ALB

```bash
make broadcast-alb-update-service
```

This:
- Updates ECS service to use ALB
- Registers task with target group
- Waits for health checks to pass

### 4. Get ALB DNS Name

```bash
make broadcast-alb-get-dns
```

Output:
```
✅ ALB DNS Name: broadcast-alb-1234567890.us-east-2.elb.amazonaws.com
```

### 5. Point Domain to ALB

**Option A: Route53**
```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id Z1234567890ABC \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "admin.racetrackstreaming.com",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [{"Value": "broadcast-alb-xxx.us-east-2.elb.amazonaws.com"}]
      }
    }]
  }'
```

**Option B: Cloudflare (Recommended - free SSL)**
1. Log into Cloudflare
2. Add DNS record: admin → ALB DNS
3. Proxy: Enabled (orange cloud)
4. Wait 5 minutes for SSL

### 6. Access Your System

```bash
# Direct via ALB DNS
curl http://broadcast-alb-1234567890.us-east-2.elb.amazonaws.com/health

# Via custom domain
curl https://admin.racetrackstreaming.com/health

# In browser
https://admin.racetrackstreaming.com
```

---

## 🏗️ Complete Deployment Architecture

```
User Browser (HTTPS)
    ↓
Cloudflare (DNS + SSL)
    ↓
AWS ALB (broadcast-alb)
    ↓
Target Group (broadcast-tg)
    ↓
ECS Task (Broadcast System)
    ↓
MediaMTX (localhost)
```

### Key Components

| Component | Purpose | Port |
|-----------|---------|------|
| **Cloudflare** | DNS + SSL/TLS termination | 443 |
| **ALB** | HTTP load balancing | 80, 443 |
| **Target Group** | Health checks + routing | 3001 |
| **ECS Task** | Broadcast application | 3001 |
| **MediaMTX** | Streaming backend | 8554, 8888, 8889 |

---

## 💡 Workflow Examples

### Full Production Deployment (First Time)

```bash
# 1. Deploy everything
make broadcast-aws-deploy

# 2. Create ALB infrastructure
make broadcast-alb-create

# 3. Connect service to ALB
make broadcast-alb-update-service

# 4. Get DNS names
make broadcast-alb-get-dns
make broadcast-aws-get-ip

# 5. Update DNS records manually or via:
export CLOUDFLARE_API_TOKEN="your-token"
export CLOUDFLARE_ZONE_ID="your-zone-id"
make cloudflare-create-records

# Result: Service available at admin.racetrackstreaming.com
```

### Quick Update (Code Changes)

```bash
# 1. Build and push
make broadcast-aws-push

# 2. Update running service
make broadcast-aws-update

# 3. Update DNS if IP changed (Cloudflare only)
make cloudflare-update-dns

# Done in ~5 minutes
```

### Cost Optimization

```bash
# Check costs
make aws-cost-estimate

# Stop compute (keep infrastructure)
make aws-stop-services

# Restart when needed
make aws-start-services

# Delete everything (irreversible)
make aws-cleanup-all
```

---

## 📊 Expected Behavior

### Healthy Service

```bash
$ make broadcast-aws-status
📊 Broadcast ECS Service Status:
Status  Running  Desired
ACTIVE  1        1

$ make broadcast-alb-get-dns
✅ ALB DNS Name: broadcast-alb-xxx.us-east-2.elb.amazonaws.com
✅ ALB is responding (HTTP 200)

$ curl https://admin.racetrackstreaming.com/health
{"status": "ok"}
```

### Unhealthy Service

```bash
$ make broadcast-aws-status
Status  Running  Desired
ACTIVE  0        1      ← Running count 0 = problem

$ make broadcast-aws-logs
ERROR: Container failed to start
ERROR: Connection refused (MediaMTX not available)

Solution: make broadcast-aws-update
```

---

## 🔧 Configuration Reference

### Makefile Variables

```makefile
BROADCAST_ALB_NAME ?= broadcast-alb
BROADCAST_ALB_TARGET_GROUP ?= broadcast-tg
BROADCAST_DOMAIN ?= admin.racetrackstreaming.com
BROADCAST_PORT ?= 443

# Can override:
make broadcast-alb-create BROADCAST_ALB_NAME=my-alb
```

### Environment Variables (Optional)

```bash
# Cloudflare API (for automated DNS updates)
export CLOUDFLARE_API_TOKEN="xxx"
export CLOUDFLARE_ZONE_ID="xxx"

# AWS
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=123456789012
```

---

## 📚 Documentation Map

| Document | Purpose | Read When |
|----------|---------|-----------|
| **BROADCAST_ALB_DEPLOYMENT.md** | Complete ALB guide | Setting up ALB |
| **AWS_DEPLOYMENT_COMMANDS.md** | Command reference | Looking for commands |
| **ARCHITECTURE_TROUBLESHOOTING.md** | Architecture & debugging | Debugging issues |
| **README.md** | Project overview | First time setup |

---

## ✅ Verification Checklist

After deployment, verify everything:

```bash
# 1. ECS service running
make broadcast-aws-status
# Expected: Running count = 1, Status = ACTIVE

# 2. ALB responding
make broadcast-alb-get-dns
# Expected: ALB DNS name shown, HTTP 200 response

# 3. Domain resolving
dig admin.racetrackstreaming.com
# Expected: Shows ALB IP or CNAME

# 4. Application accessible
curl https://admin.racetrackstreaming.com
# Expected: HTML response from Broadcast system

# 5. Health endpoint
curl https://admin.racetrackstreaming.com/health
# Expected: {"status": "ok"}

# 6. SSL certificate valid
openssl s_client -connect admin.racetrackstreaming.com:443
# Expected: Green lock in browser, cert from DigiCert or Google Trust Services
```

---

## 🚨 Common Issues & Solutions

### Issue: "Connection refused"

**Cause:** ALB not properly configured or task not running

**Solution:**
```bash
make broadcast-aws-status          # Check if task running
make broadcast-aws-logs            # Check logs
make broadcast-aws-update          # Restart service
sleep 120                          # Wait 2 minutes
curl https://admin.racetrackstreaming.com/health
```

### Issue: "503 Service Unavailable"

**Cause:** Task unhealthy or not registered with target group

**Solution:**
```bash
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --names broadcast-tg \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)
# Should show: State = healthy, Reason = N/A
```

### Issue: "SSL certificate error"

**Cause:** Self-signed certificate or domain mismatch

**Solution:**
```bash
# Use Cloudflare for free DigiCert certificate
make cloudflare-setup-guide
```

### Issue: "High monthly costs"

**Cause:** ALB always running even when not needed

**Solution:**
```bash
# Option 1: Stop compute (keep ALB)
make aws-stop-services

# Option 2: Delete ALB (keep ECS)
make broadcast-alb-cleanup

# Option 3: Delete everything
make aws-cleanup-all
```

---

## 📈 Monitoring & Maintenance

### Daily
```bash
make broadcast-aws-logs          # Check for errors
make broadcast-aws-status        # Verify running
```

### Weekly
```bash
make aws-list-resources          # See what's running
make aws-cost-estimate           # Check costs
make dns-check                   # Verify domain
```

### Monthly
```bash
make broadcast-aws-logs | grep ERROR  # Check for patterns
curl https://admin.racetrackstreaming.com/health  # Test endpoint
```

---

## 🎯 Next Steps

1. **Read Full Guides:**
   - `BROADCAST_ALB_DEPLOYMENT.md` - Complete setup guide
   - `ARCHITECTURE_TROUBLESHOOTING.md` - Understand architecture

2. **Deploy to Production:**
   - Follow "Quick Start" above
   - Run verification checklist
   - Monitor logs

3. **Enable HTTPS:**
   - Option A: Use Cloudflare (free SSL)
     ```bash
     make cloudflare-setup-guide
     ```
   - Option B: Use AWS Certificate Manager
     ```bash
     aws acm request-certificate --domain-name admin.racetrackstreaming.com
     ```

4. **Set Up Monitoring:**
   - Enable CloudWatch alarms
   - Configure log retention
   - Set up health checks

---

## 📞 Support & Resources

### AWS Documentation
- [ALB Guide](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/)
- [ECS Guide](https://docs.aws.amazon.com/ecs/)
- [Route53 Guide](https://docs.aws.amazon.com/route53/)

### Cloudflare Documentation
- [Cloudflare DNS](https://developers.cloudflare.com/dns/)
- [SSL/TLS](https://developers.cloudflare.com/ssl/)

### Project Documentation
- All `.md` files in project root
- Makefile comments: `grep "##" Makefile`

---

## 🎓 Key Learnings

### What the ALB does
- ✅ Terminates HTTPS connections
- ✅ Routes traffic to healthy tasks
- ✅ Performs health checks every 30 seconds
- ✅ Automatically removes unhealthy tasks
- ✅ Scales with multiple tasks

### What you can do now
- ✅ Deploy Broadcast at professional domain
- ✅ Secure with free Cloudflare SSL
- ✅ Scale to multiple instances
- ✅ Monitor health automatically
- ✅ Deploy updates without downtime

### What costs money
- ✅ ALB: ~$28/month
- ✅ ECS Fargate: ~$9/month per task
- ✅ Optional: AWS Certificate Manager, CloudWatch

---

## 🏁 Conclusion

You now have:

1. ✅ **9 new Makefile targets** for Broadcast ALB management
2. ✅ **3 comprehensive guides** for setup and troubleshooting
3. ✅ **Production-ready** deployment pipeline
4. ✅ **Monitoring** and **health checks** automated
5. ✅ **Free HTTPS** via Cloudflare SSL

### To Get Started:

```bash
# See all new commands
grep "broadcast-alb" Makefile | grep "##"

# Deploy everything
make broadcast-aws-deploy
make broadcast-alb-create
make broadcast-alb-update-service

# Get URL
make broadcast-alb-get-dns

# Access
https://admin.racetrackstreaming.com
```

Good luck! 🚀
