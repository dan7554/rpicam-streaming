# AWS Deployment Commands Reference

Quick reference for all deployment commands across MediaMTX and Broadcast systems.

## 🎬 Broadcast System Deployment

### Full Broadcast Deployment (10 minutes)

```bash
# 1. Deploy Broadcast system to ECS (creates cluster, service, logs, task definition)
make broadcast-aws-deploy

# 2. Create ALB for domain access
make broadcast-alb-create

# 3. Connect Broadcast service to ALB
make broadcast-alb-update-service

# 4. Get ALB DNS name and test
make broadcast-alb-get-dns

# Result: Service available at admin.racetrackstreaming.com
```

### Quick Broadcast Update (After code changes)

```bash
# 1. Build and push to ECR
make broadcast-aws-push

# 2. Update ECS service (new task deployed)
make broadcast-aws-update

# 3. Update DNS if needed (IP changed)
make broadcast-aws-update-dns
```

### Monitor Broadcast

```bash
# Check service status
make broadcast-aws-status

# View live logs
make broadcast-aws-logs

# Get current task IP
make broadcast-aws-get-ip

# Test connectivity
curl https://admin.racetrackstreaming.com/health
```

### Stop/Start Broadcast (Pause billing)

```bash
# Stop compute charges
make aws-stop-services

# Or broadcast only
aws ecs update-service \
  --cluster broadcast-cluster \
  --service broadcast-service \
  --desired-count 0

# Restart later
make aws-start-services
```

---

## 📡 MediaMTX Deployment

### Full MediaMTX Deployment (10 minutes)

```bash
# 1. Setup complete ECS infrastructure
make ecs-setup

# 2. Build and push to ECR
make ecr-push

# 3. Create ALB for MediaMTX
make alb-create

# 4. Connect MediaMTX service to ALB
make alb-update-service

# 5. Get ALB DNS and test
make alb-get-dns

# Result: MediaMTX available at stream.racetrackstreaming.com
```

### Quick MediaMTX Update

```bash
# Build and push
make ecr-push

# Update ECS service
make ecs-update

# Get new URL
make ecs-get-url
```

### Monitor MediaMTX

```bash
# Check status
make ecs-status

# View logs
make ecs-logs

# Test stream
curl rtsp://localhost:8554/rpicam2
```

---

## 🌐 DNS & Domain Setup

### Setup Cloudflare DNS (Free SSL)

```bash
# See setup instructions
make cloudflare-setup-guide

# Create DNS records (requires API token)
export CLOUDFLARE_API_TOKEN="your-token"
export CLOUDFLARE_ZONE_ID="your-zone-id"
make cloudflare-create-records

# Update DNS when IPs change
make cloudflare-update-dns
```

### Route53 DNS Setup

```bash
# Create CNAME for Broadcast
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

# Create CNAME for MediaMTX
aws route53 change-resource-record-sets \
  --hosted-zone-id Z1234567890ABC \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "stream.racetrackstreaming.com",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [{"Value": "mediamtx-alb-xxx.us-east-2.elb.amazonaws.com"}]
      }
    }]
  }'
```

### Test DNS

```bash
# Quick test
make dns-check

# For Broadcast
dig admin.racetrackstreaming.com
curl https://admin.racetrackstreaming.com

# For MediaMTX
dig stream.racetrackstreaming.com
curl http://stream.racetrackstreaming.com:8888
```

---

## 💰 Cost Management

### View Cost Estimate

```bash
make aws-cost-estimate

# Typical costs:
# - Broadcast ALB: ~$28/month
# - MediaMTX ALB: ~$28/month
# - ECS Fargate (2 tasks): ~$18/month
# - ECR storage: ~$0.20/month
# - CloudWatch logs: ~$2/month
# - Route53: ~$0.50/month
# Total: ~$77/month
```

### Stop All Compute (Keep infrastructure)

```bash
# Stop all ECS tasks (save ~$18/month)
make aws-stop-services

# Restart later
make aws-start-services
```

### Delete Everything (Cleanup)

```bash
# Delete all AWS resources (irreversible!)
make aws-cleanup  # With confirmation prompt
make aws-cleanup-all  # Force delete

# Keep:
# - DNS records (needed for DNS to work)
# - CloudWatch log retention settings
```

---

## 🚀 Full Production Pipeline

### Initial Setup

```bash
# 1. Deploy Broadcast
make broadcast-aws-deploy

# 2. Deploy MediaMTX
make ecs-setup
make ecr-push
make ecs-update

# 3. Setup ALBs
make broadcast-alb-create
make broadcast-alb-update-service
make alb-create
make alb-update-service

# 4. Get DNS names
make broadcast-alb-get-dns
make alb-get-dns

# 5. Setup Cloudflare
make cloudflare-setup-guide

# 6. Test everything
make broadcast-aws-status
make ecs-status
curl https://admin.racetrackstreaming.com
curl http://stream.racetrackstreaming.com:8888
```

### Regular Updates

```bash
# Update Broadcast code
make broadcast-aws-push
make broadcast-aws-update

# Update MediaMTX config
make ecr-push
make ecs-update

# Restart if needed
make broadcast-aws-update-dns
make dns-check
```

### Maintenance

```bash
# Monthly cost review
make aws-list-resources
make aws-cost-estimate

# Check health
make broadcast-aws-status
make ecs-status
make broadcast-aws-logs
make ecs-logs

# Update DNS if IPs changed
make broadcast-aws-update-dns
```

---

## 🔧 Configuration Variables

Set these in your shell or Makefile:

```bash
# AWS
export AWS_REGION=us-east-2
export AWS_ACCOUNT_ID=123456789012

# Broadcast
export BROADCAST_DOMAIN=admin.racetrackstreaming.com
export BROADCAST_PORT=443
export BROADCAST_ECS_CLUSTER=broadcast-cluster
export BROADCAST_ECS_SERVICE=broadcast-service

# MediaMTX
export DOMAIN_NAME=stream.racetrackstreaming.com
export ECS_CLUSTER_NAME=mediamtx-cluster
export ECS_SERVICE_NAME=mediamtx-service

# Cloudflare (optional)
export CLOUDFLARE_API_TOKEN="your-token"
export CLOUDFLARE_ZONE_ID="your-zone-id"

# AWS Certificate Manager (optional)
export CERTIFICATE_ARN="arn:aws:acm:..."
```

---

## 📋 Makefile Targets Summary

### Broadcast System Targets

```bash
make broadcast-build                    # Build Broadcast image
make broadcast-aws-build               # Build for AWS (AMD64)
make broadcast-aws-push                # Build and push to ECR
make broadcast-aws-deploy              # Full ECS deployment
make broadcast-aws-update              # Update running service
make broadcast-aws-logs                # View logs
make broadcast-aws-status              # Check status

make broadcast-alb-create              # Create ALB
make broadcast-alb-update-service      # Connect service to ALB
make broadcast-alb-get-dns             # Get ALB DNS name
make broadcast-alb-cleanup             # Delete ALB
```

### MediaMTX Targets

```bash
make ecr-push                          # Build and push to ECR
make ecs-setup                         # Full ECS setup
make ecs-deploy                        # Deploy to ECS
make ecs-update                        # Update running service
make ecs-logs                          # View logs
make ecs-status                        # Check status

make alb-create                        # Create ALB
make alb-update-service                # Connect service to ALB
make alb-get-dns                       # Get ALB DNS name
make alb-cleanup                       # Delete ALB
```

### DNS Targets

```bash
make dns-setup                         # Show setup instructions
make dns-create-cname                  # Create CNAME record (Route53)
make dns-check                         # Test resolution and connectivity
make dns-validate                      # Comprehensive validation

make cloudflare-setup-guide            # Show Cloudflare setup
make cloudflare-create-records         # Create DNS records (requires API)
make cloudflare-update-dns             # Update existing records
```

### Cleanup Targets

```bash
make aws-cleanup                       # Interactive cleanup with confirmation
make aws-cleanup-all                   # Force delete all resources
make broadcast-alb-cleanup             # Delete Broadcast ALB only
make broadcast-aws-cleanup             # Delete Broadcast ECS only
make alb-cleanup                       # Delete MediaMTX ALB only
make ecs-cleanup                       # Delete MediaMTX ECS only
```

---

## 🔐 Security Best Practices

### 1. Use HTTPS Always

```bash
# Enable Cloudflare SSL (free)
make cloudflare-setup-guide

# Or AWS Certificate Manager (free for AWS resources)
# Then set CERTIFICATE_ARN and redeploy ALB
```

### 2. Restrict Security Groups

```bash
# Limit traffic to specific IPs or security groups
aws ec2 modify-security-group-rules \
  --group-id sg-xxxxx \
  --security-group-rules '[{
    "GroupId": "sg-xxxxx",
    "CidrIp": "YOUR-IP/32",
    "IpProtocol": "tcp",
    "FromPort": 443
  }]'
```

### 3. Rotate API Tokens

```bash
# For Cloudflare API token
# Create new token, update environment variable
# Delete old token in Cloudflare dashboard
```

### 4. Monitor Logs

```bash
# Enable CloudWatch log retention
aws logs put-retention-policy \
  --log-group-name /ecs/broadcast \
  --retention-in-days 30

# Monitor for errors
make broadcast-aws-logs | grep ERROR
```

---

## 🆘 Troubleshooting

### Service Not Starting

```bash
# Check ECS logs
make broadcast-aws-logs

# Check task definition
aws ecs describe-task-definition \
  --task-definition broadcast-task

# Check task status
make broadcast-aws-status

# Restart service
make broadcast-aws-update
```

### ALB Not Responding

```bash
# Check target health
aws elbv2 describe-target-health \
  --target-group-arn <TG-ARN>

# Should show: State.Reason = "Target registration is still in progress"
# or "N/A" with TargetHealth.State = "healthy"

# Wait 1-2 minutes and retry
sleep 120
curl http://<ALB-DNS>/health
```

### DNS Not Resolving

```bash
# Check DNS record
dig admin.racetrackstreaming.com

# Verify ALB is responding
curl -v http://<ALB-DNS>/health

# Wait for propagation (5-30 minutes)
# Then test again
```

### High Costs

```bash
# Check what's running
make aws-list-resources

# Estimate costs
make aws-cost-estimate

# Stop unused services
make aws-stop-services

# Or delete everything
make aws-cleanup-all
```

---

## 📚 Documentation

- `BROADCAST_ALB_DEPLOYMENT.md` - Detailed ALB setup guide
- `BROADCASTING_SYSTEM_README.md` - Broadcast system guide
- Makefile comments - Individual target documentation

```bash
# View all available commands
make help

# View command details
grep "## " Makefile | head -50
```

---

## 🎯 Next Steps

1. **Deploy Broadcast:** `make broadcast-aws-deploy`
2. **Setup ALB:** `make broadcast-alb-create && make broadcast-alb-update-service`
3. **Configure DNS:** Point domain to ALB DNS name
4. **Enable HTTPS:** `make cloudflare-setup-guide`
5. **Monitor:** `make broadcast-aws-logs`

Good luck! 🚀
