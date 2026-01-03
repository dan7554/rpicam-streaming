# MediaMTX/Broadcast System Architecture Review & SSL Configuration Analysis

**Date:** December 13, 2025  
**Status:** Architecture Review Complete - SSL Configuration Recommended

---

## Executive Summary

Your MediaMTX/Broadcast System architecture is well-designed with proper service separation, but **SSL/TLS configuration is incomplete in the Makefile**. The infrastructure supports multiple SSL options, but the Makefile lacks:

1. **ALB HTTPS Listener setup** (443)
2. **AWS ACM certificate integration**
3. **Cloudflare SSL bridge configuration**
4. **Port 443 mapping in task definitions**

---

## Current Architecture Overview

### Services Topology

```
┌─────────────────────────────────────────────────────────────┐
│                     CLOUDFLARE (DNS)                         │
│              admin.racetrackstreaming.com                    │
└────────────────────────┬────────────────────────────────────┘
                         │ (CNAME record)
                         ↓
┌─────────────────────────────────────────────────────────────┐
│                   AWS ALB (Port 80/443)                      │
│            broadcast-alb (sg-0693f1de9c2f66aef)              │
├─────────────────────────────────────────────────────────────┤
│  Listener:80 (HTTP)        →  Redirect to HTTPS             │
│  Listener:443 (HTTPS)      →  ❌ NOT CONFIGURED             │
│  Health Check: /health     →  Target Group port 80          │
└──────────┬──────────────────────────┬──────────────────────┘
           │                          │
    ┌──────▼──────────┐       ┌──────▼──────────┐
    │ ECS Security Gr │       │ Target Group    │
    │ sg-084ba...     │       │ broadcast-       │
    │                │       │ targets:80      │
    └──────┬──────────┘       └──────┬──────────┘
           │                          │
    ┌──────▼──────────────────────────▼──────────┐
    │        ECS FARGATE Cluster                 │
    │       broadcast-cluster                    │
    ├────────────────────────────────────────────┤
    │                                            │
    │  📺 BROADCAST-SYSTEM Service              │
    │  ├─ Task: broadcast-system:latest (ECR)   │
    │  ├─ CPU: 256 (0.25 vCPU)                  │
    │  ├─ RAM: 512 MB                           │
    │  ├─ Port Mapping:                         │
    │  │  ├─ Container 80 (nginx HTTP)          │
    │  │  ├─ Container 443 (nginx HTTPS) ❌     │
    │  │  └─ Container 3001 (Express)           │
    │  └─ Containers:                           │
    │     ├─ Nginx (reverse proxy + SSL/TLS)    │
    │     └─ Express.js (API server)            │
    │                                            │
    │  📡 MEDIAMTX Service (Internal)           │
    │  ├─ Task: mediamtx:latest                 │
    │  ├─ CPU: 512 (0.5 vCPU)                   │
    │  ├─ RAM: 1024 MB                          │
    │  ├─ Port Mapping:                         │
    │  │  ├─ 8554 (RTSP input)                  │
    │  │  ├─ 8888 (HLS output)                  │
    │  │  ├─ 8889 (WebRTC output)               │
    │  │  └─ 1935 (RTMP input/output)           │
    │  └─ Service Discovery: mediamtx-          │
    │     service.broadcast-cluster.ecs.local   │
    │                                            │
    └────────────────────────────────────────────┘
           │                  │
    ┌──────▼──────────┐ ┌─────▼──────────┐
    │   Cameras       │ │  YouTube/RTMP  │
    │  (RTSP Streams) │ │   (RTMP Output)│
    └─────────────────┘ └────────────────┘
```

---

## 🔍 Detailed Component Analysis

### 1. **MediaMTX Service** ✅ Well Configured
- **Status:** Properly isolated internal service
- **Network:** awsvpc mode with service discovery
- **Ports:** RTSP(8554), HLS(8888), WebRTC(8889), RTMP(1935)
- **Resources:** Appropriately sized (512 CPU, 1GB RAM)
- **Logging:** CloudWatch configured
- **Health Check:** HTTP on port 9997 (/v3/paths/list)

**Issues:** None identified

---

### 2. **Broadcast-System Service** ⚠️ Partially Configured

#### ✅ What's Working:
- Docker image includes Nginx + Express.js stack
- Dockerfile installs nginx, SSL tools (openssl, ca-certificates)
- `nginx-ssl.conf` exists with complete SSL/TLS configuration:
  - Port 80: HTTP → HTTPS redirect + /health endpoint
  - Port 443: HTTPS with SSL certificates + proxying
  - Port 8888: Health check alternative endpoint
- `docker-entrypoint.sh` generates self-signed certificates on startup
- Task definition includes port mappings for 80 and 443
- Environment variables for MediaMTX URL passed correctly

#### ❌ What's Missing in Makefile:

1. **No ALB HTTPS Listener (Port 443)**
   ```
   Missing: aws elbv2 create-listener for port 443
   Impact: Users cannot access via HTTPS
   ```

2. **No AWS ACM Certificate Integration**
   ```
   Missing: Certificate ARN in listener configuration
   Missing: make target to request/validate ACM certificates
   Impact: ALB can't terminate SSL for Cloudflare
   ```

3. **No Cloudflare SSL Bridge Setup**
   ```
   Missing: Configuration guide for Cloudflare Full (Strict) mode
   Missing: ALB HTTPS → Cloudflare HTTPS chain
   Impact: Security chain incomplete
   ```

4. **Port 443 Not Exposed in Task Definition**
   ```
   Current Makefile (line ~257):
   "portMappings": [
     {"containerPort": 80, ...},
     {"containerPort": 443, ...}  ← Present but ALB not configured to use it
   ]
   ```

5. **Health Check Not Leveraging HTTPS**
   ```
   Current: curl http://localhost/health
   Missing: curl -k https://localhost/health option
   ```

---

### 3. **ALB Configuration** ⚠️ Incomplete

#### Current State:
- ✅ ALB exists: `broadcast-alb`
- ✅ Target Group exists: `broadcast-targets` (port 80)
- ✅ HTTP listener (port 80) configured
- ❌ HTTPS listener (port 443) NOT configured
- ❌ No SSL certificate attached to ALB

#### Flow Currently:
```
User → Cloudflare (handles SSL) → ALB:80 (HTTP) → Target Group:80 → Container:80 (nginx)
```

#### Recommended Flow (Secure):
```
User → Cloudflare (optional) → ALB:443 (HTTPS) → Target Group:80 → Container:80 (nginx)
```

---

## 🔐 SSL/TLS Configuration Options

### Option A: AWS Certificate Manager (ACM) + ALB Termination ⭐ Recommended

**Pros:**
- Native AWS integration
- Zero additional cost
- Automatic certificate renewal
- Simple setup in Makefile

**Cons:**
- Certificate validation required (email or DNS)
- Requires domain ownership

**Implementation:**
```bash
# 1. Request certificate
aws acm request-certificate \
  --domain-name admin.racetrackstreaming.com \
  --validation-method DNS

# 2. Validate DNS record (Cloudflare)
# 3. Add HTTPS listener to ALB pointing to ACM certificate
```

**Makefile Changes Needed:**
```makefile
# Add variables
ACM_CERT_ARN := arn:aws:acm:us-east-1:xxx:certificate/xxx
ALB_HTTPS_PORT := 443

# Add target
acm-request-cert:
    @aws acm request-certificate \
      --domain-name $(DOMAIN) \
      --validation-method DNS \
      --region $(AWS_REGION)

# Add listener
alb-create-https-listener:
    @aws elbv2 create-listener \
      --load-balancer-arn $$ALB_ARN \
      --protocol HTTPS \
      --port 443 \
      --certificates CertificateArn=$$ACM_CERT_ARN \
      --default-actions Type=forward,TargetGroupArn=$$TARGET_GROUP_ARN
```

---

### Option B: Cloudflare SSL Only (Current Approach)

**Pros:**
- Completely free SSL
- No AWS certificate management
- Cloudflare handles DDoS protection
- Works immediately

**Cons:**
- Self-signed certificates in ALB (not ideal)
- Less integrated with AWS ecosystem
- Requires Cloudflare account

**Current Flow:**
```
User (HTTPS) → Cloudflare (decrypts) → ALB:80 (HTTP) → Nginx (self-signed, unused)
```

**Issue:** Nginx's self-signed cert in container is unused/wasted

---

### Option C: Self-Signed (Current Container Setup)

**Status:** Already implemented in container but not accessible to users

**Why it works in container:**
- `docker-entrypoint.sh` generates self-signed cert on startup
- Nginx configured to use it on port 443
- Health checks work internally

**Why users don't see it:**
- ALB only listens on port 80 (HTTP)
- Users go through Cloudflare which terminates SSL
- Container's HTTPS port (443) never exposed

---

## 📋 Architecture Assessment Checklist

| Component | Status | Details |
|-----------|--------|---------|
| **MediaMTX Isolation** | ✅ | Properly internal service |
| **Service Discovery** | ✅ | ECS native with DNS |
| **Port Mappings** | ⚠️ | Missing ALB:443 listener |
| **Container SSL/TLS** | ✅ | Self-signed certificates working |
| **ALB HTTP Listener** | ✅ | Port 80 configured |
| **ALB HTTPS Listener** | ❌ | **MISSING** - No port 443 listener |
| **ACM Integration** | ❌ | **MISSING** - No certificate ARN |
| **Cloudflare Integration** | ⚠️ | Documented but not in Makefile |
| **Security Groups** | ✅ | Properly configured |
| **CloudWatch Logging** | ✅ | Both services logging |
| **Health Checks** | ✅ | Working on port 80 |
| **Task Definitions** | ✅ | Correct configuration |
| **Container Resources** | ✅ | Appropriately sized |

---

## 🎯 Recommended Makefile Improvements

### Priority 1: Critical (Security)
1. Add ACM certificate request target
2. Add ALB HTTPS listener (port 443)
3. Update health check to validate both HTTP and HTTPS paths

### Priority 2: Important (Operations)
4. Add certificate validation tracking
5. Add DNS record validation helper
6. Add listener verification in status command

### Priority 3: Nice to Have (Documentation)
7. Add Cloudflare setup guide target
8. Add SSL troubleshooting guide
9. Add certificate renewal reminders

---

## 📝 Proposed Makefile Changes

### Add to Global Configuration (line ~75):
```makefile
# SSL/Certificate Configuration
ACM_CERT_ARN ?= arn:aws:acm:$(AWS_REGION):$(AWS_ACCOUNT_ID):certificate/xxxxx
ALB_HTTPS_PORT := 443
CERT_DOMAIN := $(DOMAIN)
```

### Add new SSL targets:

```makefile
###############################################
# SSL/CERTIFICATE MANAGEMENT
###############################################

.PHONY: acm-request-cert acm-list-certs acm-validate-dns alb-create-https-listener ssl-setup

acm-request-cert: ## 🔐 Request ACM certificate for domain
	@echo "🔐 Requesting ACM certificate for $(CERT_DOMAIN)..."
	@aws acm request-certificate \
	  --domain-name $(CERT_DOMAIN) \
	  --subject-alternative-names \*.$(CERT_DOMAIN) \
	  --validation-method DNS \
	  --region $(AWS_REGION) \
	  --query 'CertificateArn' \
	  --output text

acm-list-certs: ## 📋 List ACM certificates
	@echo "📋 ACM Certificates in $(AWS_REGION):"
	@aws acm list-certificates \
	  --region $(AWS_REGION) \
	  --query 'CertificateSummaryList[*].[CertificateArn,DomainName,Status]' \
	  --output table

acm-validate-dns: ## ✅ Validate ACM certificate via DNS (Cloudflare)
	@echo "✅ ACM Validation Records:"
	@echo "   Add these DNS records in Cloudflare:"
	@aws acm describe-certificate \
	  --certificate-arn $(ACM_CERT_ARN) \
	  --region $(AWS_REGION) \
	  --query 'Certificate.DomainValidationOptions[*].[DomainName,ResourceRecord.{Name:Name,Type:Type,Value:Value}]' \
	  --output table

alb-create-https-listener: ## 🔗 Create HTTPS listener on ALB
	@echo "🔗 Creating HTTPS listener on ALB..."
	@ALB_ARN=$$(aws elbv2 describe-load-balancers \
	  --region $(AWS_REGION) \
	  --names $(ALB_NAME) \
	  --query 'LoadBalancers[0].LoadBalancerArn' \
	  --output text); \
	TARGET_GROUP_ARN=$$(aws elbv2 describe-target-groups \
	  --region $(AWS_REGION) \
	  --names $(ALB_TG_NAME) \
	  --query 'TargetGroups[0].TargetGroupArn' \
	  --output text); \
	if [ -z "$$ALB_ARN" ] || [ -z "$$TARGET_GROUP_ARN" ]; then \
	  echo "❌ ALB or Target Group not found"; \
	  exit 1; \
	fi; \
	aws elbv2 create-listener \
	  --load-balancer-arn $$ALB_ARN \
	  --protocol HTTPS \
	  --port $(ALB_HTTPS_PORT) \
	  --certificates CertificateArn=$(ACM_CERT_ARN) \
	  --default-actions Type=forward,TargetGroupArn=$$TARGET_GROUP_ARN \
	  --region $(AWS_REGION) 2>/dev/null && \
	echo "✅ HTTPS listener created" || echo "⚠️  Listener may already exist"

alb-update-listener: ## 🔄 Update HTTPS listener certificate
	@echo "🔄 Updating HTTPS listener certificate..."
	@LISTENER_ARN=$$(aws elbv2 describe-listeners \
	  --load-balancer-arn $$(aws elbv2 describe-load-balancers \
	    --names $(ALB_NAME) \
	    --query 'LoadBalancers[0].LoadBalancerArn' \
	    --output text \
	    --region $(AWS_REGION)) \
	  --query "Listeners[?Port==$(ALB_HTTPS_PORT)].ListenerArn" \
	  --output text \
	  --region $(AWS_REGION)); \
	aws elbv2 modify-listener \
	  --listener-arn $$LISTENER_ARN \
	  --certificates CertificateArn=$(ACM_CERT_ARN) \
	  --region $(AWS_REGION)
	@echo "✅ Listener certificate updated"

ssl-setup: acm-list-certs ## 🔐 Complete SSL setup (request cert, create listener)
	@echo "🔐 SSL Setup Instructions:"
	@echo ""
	@echo "1. Set ACM_CERT_ARN in Makefile or environment"
	@echo "2. Run: make acm-request-cert"
	@echo "3. Run: make acm-validate-dns (add records to Cloudflare)"
	@echo "4. Wait for validation (check with: make acm-list-certs)"
	@echo "5. Run: make alb-create-https-listener"
	@echo ""
	@echo "For Cloudflare only (skip ACM):"
	@echo "   Just set Cloudflare SSL mode to 'Full (Strict)'"
	@echo ""
```

### Update broadcast-task-def to include PORT 3001 in environment (line ~267):
```makefile
\"environment\": [ \
  {\"name\": \"NODE_ENV\", \"value\": \"production\"}, \
  {\"name\": \"PORT\", \"value\": \"3001\"}, \
  {\"name\": \"BROADCAST_HOSTNAME\", \"value\": \"$(DOMAIN)\"}, \
  {\"name\": \"MEDIAMTX_URL\", \"value\": \"$(MEDIAMTX_SERVICE_URL)\"} \
],
```

### Update status target to show HTTPS listener (line ~380):
```makefile
@echo "🌐 ALB Listeners:"
@ALB_ARN=$$(aws elbv2 describe-load-balancers \
  --region $(AWS_REGION) \
  --names $(ALB_NAME) \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text 2>/dev/null); \
if [ -n "$$ALB_ARN" ]; then \
  aws elbv2 describe-listeners \
    --load-balancer-arn $$ALB_ARN \
    --region $(AWS_REGION) \
    --query 'Listeners[].{Port:Port,Protocol:Protocol,Certificate:Certificates[0].CertificateArn}' \
    --output table 2>/dev/null || echo "  (unable to retrieve)"; \
else \
  echo "  (ALB not found)"; \
fi
```

---

## 🚀 Implementation Roadmap

### Immediate (Do Now):
- [ ] Review and identify ACM certificate ARN
- [ ] Update Makefile with ACM_CERT_ARN variable
- [ ] Add SSL targets to Makefile
- [ ] Document in updated help text

### Short-term (Next Sprint):
- [ ] Request ACM certificate (if not already done)
- [ ] Create ALB HTTPS listener
- [ ] Test HTTPS access via ALB
- [ ] Verify Cloudflare integration

### Medium-term (Polish):
- [ ] Add SSL troubleshooting commands
- [ ] Create certificate rotation automation
- [ ] Add monitoring for certificate expiration
- [ ] Document in README

---

## ✅ Final Recommendations

### Do This (High Impact):
1. **Add ACM HTTPS Listener** - Users need secure HTTPS access
2. **Update Makefile with SSL targets** - Easier certificate management
3. **Document certificate validation** - Prevent future SSL errors

### Consider This:
1. **Cloudflare + ACM combined** - Best of both worlds (DDoS + AWS integration)
2. **Automated certificate renewal** - Prevent expiration issues
3. **SSL/TLS monitoring** - Alert before expiration

### Don't Need:
- ~~Manual certificate management~~ (Use ACM)
- ~~Complex Docker cert mounting~~ (Already in container)
- ~~HTTP-only infrastructure~~ (Security risk)

---

## Summary Table: Architecture Health

| Area | Status | Score | Notes |
|------|--------|-------|-------|
| Service Isolation | ✅ | 10/10 | Perfect separation between MediaMTX and Broadcast |
| Port Mapping | ⚠️ | 7/10 | Port 443 in container but not exposed via ALB |
| Load Balancing | ⚠️ | 7/10 | HTTP working; HTTPS listener missing |
| SSL/TLS Setup | ⚠️ | 6/10 | Container ready; ALB integration incomplete |
| Documentation | ✅ | 8/10 | Good guides exist; not integrated in Makefile |
| Scaling | ✅ | 9/10 | ECS Fargate handles auto-scaling |
| Logging | ✅ | 10/10 | CloudWatch properly configured |
| Health Checks | ✅ | 9/10 | Working; could add HTTPS variant |
| **OVERALL** | **⚠️** | **7.6/10** | **Needs SSL listener in ALB** |

---

## Recommended Next Steps

1. **Run diagnostics:**
   ```bash
   make status              # Show current configuration
   make debug-env           # Show all settings
   make acm-list-certs      # Check available certificates
   ```

2. **If ACM certificate exists:**
   ```bash
   make alb-create-https-listener ACM_CERT_ARN="arn:aws:acm:..."
   ```

3. **If no ACM certificate:**
   ```bash
   make acm-request-cert
   make acm-validate-dns    # Add records to Cloudflare
   # Wait for validation
   make alb-create-https-listener
   ```

4. **Test access:**
   ```bash
   https://admin.racetrackstreaming.com  # Should work now
   curl -v https://admin.racetrackstreaming.com/health
   ```

---

**Ready to implement SSL configuration? Let me know which option you prefer (ACM, Cloudflare-only, or hybrid).**
