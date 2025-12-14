# Broadcast System ALB Deployment Guide

This guide explains how to deploy the Broadcast system with AWS Application Load Balancer (ALB) for production access at `admin.racetrackstreaming.com`.

## Overview

The Broadcast ALB provides:
- **HTTPS termination** for secure connections
- **SSL/TLS certificates** from AWS or Cloudflare
- **Domain-based routing** for professional access
- **Automatic health checks** and failover
- **Load balancing** across multiple instances (if needed)

## Prerequisites

✅ **Required:**
- AWS account with credentials configured (`aws configure`)
- Broadcast system deployed to ECS: `make broadcast-aws-deploy`
- Domain `racetrackstreaming.com` in Route53 or Cloudflare
- SSL certificate (can use free Let's Encrypt or AWS ACM)

✅ **Optional:**
- Cloudflare account (for DNS + SSL proxy)
- AWS Certificate Manager certificate for HTTPS

## Quick Start (5 minutes)

### Step 1: Create the ALB Infrastructure

```bash
# Create target group, ALB, and listeners
make broadcast-alb-create

# Verify it was created
make broadcast-alb-info
```

### Step 2: Update the Broadcast Service to Use ALB

```bash
# Connect your ECS service to the ALB
make broadcast-alb-update-service

# Wait 1-2 minutes for the task to be registered with the target group
```

### Step 3: Get the ALB DNS Name

```bash
make broadcast-alb-get-dns
```

You'll see output like:
```
✅ ALB DNS Name: broadcast-alb-1234567890.us-east-2.elb.amazonaws.com

🎯 Broadcast URLs through ALB:
  🎬 Admin Panel: http://broadcast-alb-1234567890.us-east-2.elb.amazonaws.com
  📡 WebRTC: http://broadcast-alb-1234567890.us-east-2.elb.amazonaws.com:8889
  🎥 RTSP: rtsp://broadcast-alb-1234567890.us-east-2.elb.amazonaws.com:8554
```

### Step 4: Point Your Domain to the ALB

**Option A: Using Route53 (AWS)**
```bash
# Create CNAME record in Route53
# Record: admin.racetrackstreaming.com → broadcast-alb-1234567890.us-east-2.elb.amazonaws.com
```

**Option B: Using Cloudflare (Recommended)**
1. Log into Cloudflare Dashboard
2. Go to DNS records for racetrackstreaming.com
3. Create A record:
   - Name: `admin`
   - Value: `<ALB-IP-ADDRESS>`
   - Proxy: **Proxied** (orange cloud) - IMPORTANT!

### Step 5: Update DNS Record

After pointing your domain to the ALB, test it:

```bash
# Test domain resolution and connectivity
make broadcast-alb-get-dns

# Or comprehensive test
make dns-check
```

## Complete Workflow

### Initial Setup (Production Deployment)

```bash
# 1. Deploy Broadcast system to ECS
make broadcast-aws-deploy

# 2. Create ALB infrastructure
make broadcast-alb-create

# 3. Connect service to ALB
make broadcast-alb-update-service

# 4. Get ALB DNS name
make broadcast-alb-get-dns

# 5. Update DNS (manual or using Cloudflare API)
# Edit your DNS provider with the ALB DNS name

# 6. Verify connectivity
make broadcast-alb-get-dns  # Should show ✅ responses
```

### Quick Updates (After Making Changes)

When you update the Broadcast code:

```bash
# 1. Rebuild and push to ECR
make broadcast-aws-push

# 2. Update ECS service (new task will be registered with ALB)
make broadcast-aws-update

# 3. Update DNS if task IP changed (Cloudflare only)
make broadcast-aws-update-dns
```

## Architecture

```
Client (HTTPS)
     ↓
  Cloudflare (SSL/TLS termination + DDoS protection)
     ↓
  ALB (HTTP - AWS handles HTTPS → HTTP conversion)
     ↓
  ECS Task (Broadcast system on port 3001)
     ↓
  MediaMTX (localhost:8554, :8888, :8889)
```

## Configuration Details

### ALB Target Group
- **Name:** `broadcast-tg`
- **Protocol:** HTTP (ALB terminates SSL)
- **Port:** 3001 (internal Broadcast app port)
- **Health check:** `/health` endpoint
- **Interval:** 30 seconds
- **Timeout:** 5 seconds

### ALB Listeners
- **HTTP (80):** Redirects to HTTPS
- **HTTPS (443):** Uses SSL certificate, forwards to target group

### Security Groups
- **ALB Security Group:** `broadcast-alb-sg`
  - Inbound: 80 (HTTP), 443 (HTTPS)
  - Outbound: All traffic

- **ECS Task Security Group:** `broadcast-sg`
  - Inbound: From ALB security group
  - Port: 3001

## DNS Setup Options

### Option 1: Route53 (AWS) - Simple CNAME

```bash
# Create CNAME record in Route53
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

### Option 2: Cloudflare - Full SSL/DNS Protection (Recommended)

**Benefits:**
- SSL certificate from DigiCert/Google Trust Services
- DDoS protection
- Automatic DNS failover
- Browser shows green lock with "CloudflareSSL"

**Setup:**
1. Add domain to Cloudflare (free plan)
2. Update nameservers at domain registrar
3. Create A record with ALB IP (Cloudflare proxied)
4. Enable "Full (Strict)" SSL mode

**Update DNS programmatically:**
```bash
export CLOUDFLARE_API_TOKEN="your-token"
export CLOUDFLARE_ZONE_ID="your-zone-id"

make broadcast-aws-update-dns  # Updates Cloudflare + Route53
```

## Troubleshooting

### ALB is not responding (HTTP 503)

**Possible causes:**
1. **Task not registered with target group**
   ```bash
   aws elbv2 describe-target-health --target-group-arn <TG-ARN>
   ```
   - Should show status: `healthy` and state: `InService`

2. **Task failed to start**
   ```bash
   make broadcast-aws-logs
   ```
   - Check for startup errors in logs

3. **Security group blocking traffic**
   ```bash
   make broadcast-alb-info
   # Check if security groups allow port 3001
   ```

**Solution:**
```bash
# Wait 2-3 minutes for task to register, then test again
sleep 120
curl -s http://<ALB-DNS>/health

# If still not working, restart the service
make broadcast-aws-update
```

### Domain not resolving

**Possible causes:**
1. **DNS record not pointing to ALB**
   - Check DNS record is pointing to ALB DNS name
   - Not an IP address (ALBs use DNS names, not IPs)

2. **DNS propagation delay**
   - DNS changes can take 5-30 minutes to propagate
   - Use `dig` to check: `dig admin.racetrackstreaming.com`

3. **Cloudflare not proxying**
   - Ensure orange cloud icon (proxied) not gray (DNS only)

**Solution:**
```bash
# Check DNS records
dig admin.racetrackstreaming.com

# Verify ALB DNS name
make broadcast-alb-get-dns

# Wait for propagation
sleep 300

# Test again
curl https://admin.racetrackstreaming.com
```

### SSL Certificate Issues

**Chrome shows insecure warning:**

1. **Using self-signed certificate**
   - Upgrade to AWS Certificate Manager or Cloudflare SSL
   - Cloudflare provides free DigiCert certificates

2. **Certificate domain mismatch**
   - Certificate must match `admin.racetrackstreaming.com`
   - Not `*.racetrackstreaming.com`

**Solution:**
```bash
# Option 1: Use Cloudflare (free SSL)
make cloudflare-setup-guide

# Option 2: Request AWS Certificate Manager certificate
aws acm request-certificate \
  --domain-name admin.racetrackstreaming.com \
  --validation-method DNS

# Then update Makefile CERTIFICATE_ARN and redeploy ALB
make broadcast-alb-create
```

## Monitoring

### Check ALB Status
```bash
make broadcast-alb-info

# More detailed
make broadcast-aws-status
```

### View Real-time Logs
```bash
make broadcast-aws-logs
```

### Test Health Endpoint
```bash
# Direct to ECS task
curl http://ECS-TASK-IP:3001/health

# Through ALB
curl http://<ALB-DNS>/health

# Through domain
curl https://admin.racetrackstreaming.com/health
```

### Monitor Target Health
```bash
# See if task is registered and healthy with ALB
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --names broadcast-tg \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text) \
  --region us-east-2
```

## Cost Implications

### ALB Costs
- **Base cost:** $22.70/month
- **LCU (Light Computing Unit) charge:** ~$5.76/month for light usage
- **Total:** ~$28/month for ALB

### Why Use ALB?
- ✅ Professional SSL/HTTPS termination
- ✅ Domain-based access (admin.racetrackstreaming.com)
- ✅ Automatic health checks and failover
- ✅ Scalable for multiple instances

## Advanced: Multiple Services

To route different subdomains to different services:

```bash
# Create multiple path rules
aws elbv2 create-rule \
  --listener-arn <LISTENER-ARN> \
  --conditions Field=host-header,Values=webrtc.racetrackstreaming.com \
  --actions Type=forward,TargetGroupArn=<WEBRTC-TG-ARN> \
  --priority 1

aws elbv2 create-rule \
  --listener-arn <LISTENER-ARN> \
  --conditions Field=host-header,Values=rtsp.racetrackstreaming.com \
  --actions Type=forward,TargetGroupArn=<RTSP-TG-ARN> \
  --priority 2
```

## Cleanup

### Remove ALB (keep ECS running)
```bash
make broadcast-alb-cleanup

# Service will still run on direct IP access
make broadcast-aws-get-ip
```

### Remove Everything
```bash
make broadcast-aws-cleanup

# If also need to remove MediaMTX
make aws-cleanup
```

## Next Steps

1. **Enable HTTPS:**
   - Use Cloudflare for free SSL: `make cloudflare-setup-guide`
   - Or request AWS Certificate Manager: `aws acm request-certificate`

2. **Monitor Production:**
   - Set up CloudWatch alarms
   - Monitor target health
   - Review logs regularly

3. **Scale Up:**
   - Increase desired task count in ECS
   - ALB will automatically load balance

4. **Add More Services:**
   - Deploy WebRTC service separately
   - Deploy RTSP gateway separately
   - Route via ALB path-based or host-based rules

## See Also

- `make broadcast-aws-deploy` - Deploy Broadcast system
- `make broadcast-alb-create` - Create ALB
- `make cloudflare-setup-guide` - Set up free SSL
- `make broadcast-aws-logs` - View logs
- `make broadcast-aws-status` - Check status
