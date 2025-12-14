#!/bin/bash
# Broadcast ALB Deployment Workflow

# This file documents the exact sequence of commands to deploy the Broadcast system
# with ALB to AWS. Copy and paste sections as needed.

################################################################################
# PHASE 1: Initial Setup (One-time, ~10 minutes)
################################################################################

echo "=== PHASE 1: Initial Setup ==="
echo "This phase sets up all AWS infrastructure for the first time"
echo ""

# Step 1: Deploy Broadcast System to ECS
echo "Step 1: Deploying Broadcast System to ECS..."
make broadcast-aws-deploy
# This creates:
# - IAM execution role
# - ECS cluster (broadcast-cluster)
# - CloudWatch log group (/ecs/broadcast)
# - Task definition (broadcast-task)
# - ECS service (broadcast-service)
# Expected output: "Broadcast system deployment complete!"

# Step 2: Wait for tasks to start
echo "Step 2: Waiting for ECS tasks to start (2-3 minutes)..."
sleep 120
make broadcast-aws-status
# Expected: Running count = 1

# Step 3: Create ALB Infrastructure
echo "Step 3: Creating Application Load Balancer..."
make broadcast-alb-create
# This creates:
# - Target group (broadcast-tg) on port 3001
# - Application Load Balancer (broadcast-alb)
# - Security groups with rules
# - HTTP listener (redirects to HTTPS)
# Expected output: "Broadcast ALB setup complete!"

# Step 4: Connect Service to ALB
echo "Step 4: Connecting Broadcast service to ALB..."
make broadcast-alb-update-service
# This:
# - Registers ECS task with ALB target group
# - Updates service configuration
# - Waits for health checks
# Expected: Service updated message

# Step 5: Verify ALB is working
echo "Step 5: Verifying ALB connectivity..."
sleep 30  # Wait for target health check
make broadcast-alb-get-dns
# Expected output:
# ✅ ALB DNS Name: broadcast-alb-1234567890.us-east-2.elb.amazonaws.com
# ✅ ALB is responding (HTTP 200)

# Step 6: Get current task IP (for manual DNS setup)
echo "Step 6: Getting current task IP..."
make broadcast-aws-get-ip
# Expected: Current IP: xxx.xxx.xxx.xxx

################################################################################
# PHASE 2: DNS Configuration (Choose ONE option)
################################################################################

echo ""
echo "=== PHASE 2: DNS Configuration ==="
echo "Choose one of these options to point your domain to the ALB"
echo ""

# OPTION A: Using Route53 (AWS)
echo "OPTION A: Route53 (AWS DNS)"
echo "============================="
echo ""
echo "Run this command to create a CNAME record in Route53:"
echo ""
echo 'aws route53 change-resource-record-sets \'
echo '  --hosted-zone-id Z1234567890ABC \'
echo '  --change-batch '"'"'{ \'
echo '    "Changes": [{ \'
echo '      "Action": "UPSERT", \'
echo '      "ResourceRecordSet": { \'
echo '        "Name": "admin.racetrackstreaming.com", \'
echo '        "Type": "CNAME", \'
echo '        "TTL": 300, \'
echo '        "ResourceRecords": [{"Value": "broadcast-alb-1234567890.us-east-2.elb.amazonaws.com"}] \'
echo '      } \'
echo '    }] \'
echo '  }'"'"
echo ""
echo "Replace:"
echo "  - Z1234567890ABC with your Route53 hosted zone ID"
echo "  - broadcast-alb-1234567890.us-east-2.elb.amazonaws.com with your ALB DNS (from Step 5)"
echo ""

# OPTION B: Using Cloudflare (Recommended)
echo "OPTION B: Cloudflare (Free SSL + DDoS Protection)"
echo "==================================================="
echo ""
echo "1. Log into Cloudflare: https://dash.cloudflare.com"
echo ""
echo "2. Go to DNS records for racetrackstreaming.com"
echo ""
echo "3. Create A record with:"
echo "   Name: admin"
echo "   Value: <ALB-IP-ADDRESS>"
echo "   Proxy: Proxied (orange cloud) ← IMPORTANT!"
echo ""
echo "4. Enable 'Full (Strict)' SSL mode:"
echo "   Dashboard → SSL/TLS → Encryption mode"
echo ""
echo "5. Wait 5 minutes for DNS propagation and SSL certificate"
echo ""

# OPTION C: Using Cloudflare API (Automated)
echo "OPTION C: Cloudflare API (Automated DNS Update)"
echo "==============================================="
echo ""
echo "Setup API token (one-time):"
echo "  1. Go to: https://dash.cloudflare.com/profile/api-tokens"
echo "  2. Create token with 'Edit zone DNS' permission"
echo "  3. Export token: export CLOUDFLARE_API_TOKEN='your-token'"
echo "  4. Get Zone ID from Cloudflare dashboard"
echo "  5. Export Zone ID: export CLOUDFLARE_ZONE_ID='your-zone-id'"
echo ""
echo "Then run:"
echo "  export CLOUDFLARE_API_TOKEN='your-token'"
echo "  export CLOUDFLARE_ZONE_ID='your-zone-id'"
echo "  make cloudflare-create-records"
echo ""

################################################################################
# PHASE 3: Verification (After DNS Setup)
################################################################################

echo ""
echo "=== PHASE 3: Verification ==="
echo "Wait 5-10 minutes after DNS setup, then verify:"
echo ""

# Test 1: DNS Resolution
echo "Test 1: DNS Resolution"
echo "======================="
echo "dig admin.racetrackstreaming.com"
echo "Expected: Shows IP address or CNAME"
echo ""

# Test 2: Direct ALB Connection
echo "Test 2: Direct ALB Connection"
echo "=============================="
echo 'curl http://$(make broadcast-alb-get-dns | grep "ALB DNS" | cut -d: -f2 | xargs)/health'
echo "Expected: HTTP 200, possibly JSON response"
echo ""

# Test 3: Via Domain
echo "Test 3: Via Custom Domain"
echo "=========================="
echo "curl -v https://admin.racetrackstreaming.com/health"
echo "Expected: HTTP 200, certificate from Cloudflare"
echo ""

# Test 4: Browser Access
echo "Test 4: Browser Access"
echo "======================"
echo "Open: https://admin.racetrackstreaming.com"
echo "Expected: Broadcast admin UI loads, green SSL lock"
echo ""

# Comprehensive test
echo "Comprehensive Test:"
make dns-check

################################################################################
# PHASE 4: Monitoring
################################################################################

echo ""
echo "=== PHASE 4: Monitoring ==="
echo "Commands to monitor your deployment:"
echo ""

echo "Real-time commands:"
echo "  make broadcast-aws-logs      # View live logs"
echo "  make broadcast-aws-status    # Check service status"
echo "  make broadcast-alb-info      # Show ALB configuration"
echo ""

echo "Troubleshooting:"
echo "  make broadcast-aws-get-ip    # Get current task IP"
echo "  make dns-check               # Verify DNS setup"
echo "  make aws-cost-estimate       # Check costs"
echo ""

echo "Setup commands (reference):"
echo "  make broadcast-alb-get-dns   # Get ALB DNS name"
echo "  make broadcast-aws-update    # Restart service"
echo ""

################################################################################
# PHASE 5: Future Updates
################################################################################

echo ""
echo "=== PHASE 5: Future Updates ==="
echo "When you make code changes to Broadcast:"
echo ""

echo "Step 1: Build and push to ECR"
echo "  make broadcast-aws-push"
echo ""

echo "Step 2: Update ECS service"
echo "  make broadcast-aws-update"
echo ""

echo "Step 3: Update DNS if needed"
echo "  make broadcast-aws-update-dns"
echo ""

echo "Step 4: Verify"
echo "  curl https://admin.racetrackstreaming.com/health"
echo ""

echo "Total time: ~5 minutes"
echo ""

################################################################################
# PHASE 6: Cost Management
################################################################################

echo ""
echo "=== PHASE 6: Cost Management ==="
echo ""

echo "Check current costs:"
echo "  make aws-cost-estimate"
echo "  Expected: ~$28/month for ALB + ~$9/month for ECS"
echo ""

echo "To pause costs (stop compute):"
echo "  make aws-stop-services"
echo "  Infrastructure (ALB, DNS) remains (~$1/month)"
echo ""

echo "To resume:"
echo "  make aws-start-services"
echo ""

echo "To delete everything (irreversible):"
echo "  make aws-cleanup-all"
echo ""

################################################################################
# Example: Complete Deployment Script
################################################################################

cat > /tmp/deploy-broadcast.sh << 'EOF'
#!/bin/bash
set -e

echo "🚀 Deploying Broadcast System with ALB"
echo "======================================"
echo ""

# Phase 1: Deploy infrastructure
echo "📦 Phase 1: Deploying ECS infrastructure..."
make broadcast-aws-deploy

echo "⏳ Waiting for tasks to start..."
sleep 120

echo "🔗 Phase 2: Creating ALB..."
make broadcast-alb-create

echo "🔄 Connecting service to ALB..."
make broadcast-alb-update-service

# Get info for DNS setup
ALB_DNS=$(make broadcast-alb-get-dns | grep "ALB DNS" | cut -d: -f2 | xargs)
TASK_IP=$(make broadcast-aws-get-ip | grep "Current IP" | cut -d: -f2 | xargs)

echo ""
echo "✅ Deployment Complete!"
echo ""
echo "📋 Next Steps:"
echo ""
echo "1. Update DNS record:"
echo "   - Route53: Create CNAME admin.racetrackstreaming.com → $ALB_DNS"
echo "   - Cloudflare: Create A record admin → $TASK_IP (proxied)"
echo ""
echo "2. Wait 5-10 minutes for DNS propagation"
echo ""
echo "3. Test:"
echo "   curl https://admin.racetrackstreaming.com/health"
echo ""
echo "4. Monitor:"
echo "   make broadcast-aws-logs"
echo ""

EOF

chmod +x /tmp/deploy-broadcast.sh

echo ""
echo "Ready to deploy? Run:"
echo "  /tmp/deploy-broadcast.sh"
echo ""

################################################################################
# Additional Reference: All ALB Commands
################################################################################

echo ""
echo "=== ALL BROADCAST ALB COMMANDS ==="
echo ""
echo "Setup:"
echo "  make broadcast-alb-create              # Create ALB"
echo "  make broadcast-alb-create-target-group # Create target group"
echo "  make broadcast-alb-create-alb          # Create load balancer"
echo "  make broadcast-alb-create-listener     # Create listeners"
echo ""
echo "Operation:"
echo "  make broadcast-alb-update-service      # Connect service to ALB"
echo "  make broadcast-alb-get-dns             # Get ALB DNS name"
echo "  make broadcast-alb-info                # Show ALB info"
echo ""
echo "Cleanup:"
echo "  make broadcast-alb-cleanup             # Delete ALB"
echo ""

################################################################################
# Quick Reference: Testing Each Component
################################################################################

echo ""
echo "=== TESTING CHECKLIST ==="
echo ""
echo "1. ECS Service Running?"
echo "   make broadcast-aws-status"
echo "   Should show: Running 1, Desired 1"
echo ""
echo "2. ALB Responding?"
echo "   make broadcast-alb-get-dns"
echo "   Should show: ✅ ALB is responding (HTTP 200)"
echo ""
echo "3. Task Health?"
echo "   aws elbv2 describe-target-health --target-group-arn <ARN>"
echo "   Should show: State = healthy"
echo ""
echo "4. DNS Resolving?"
echo "   dig admin.racetrackstreaming.com"
echo "   Should show: IP or CNAME"
echo ""
echo "5. HTTPS Working?"
echo "   curl -v https://admin.racetrackstreaming.com"
echo "   Should show: HTTP 200, certificate from Cloudflare"
echo ""

echo "✨ Deployment workflow complete!"
