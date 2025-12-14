# SSL/TLS Implementation Checklist

## Overview

This document tracks the complete SSL/TLS implementation from Cloudflare → ALB → ECS Container → Applications.

---

## ✅ Phase 1: Certificate Preparation (COMPLETED)

- [x] **ACM Certificate Requested**
  - ARN: `arn:aws:acm:us-east-1:457553343935:certificate/0c30493b-0262-455a-9773-2d077be5db53`
  - Status: PENDING_VALIDATION
  - Domains: racetrackstreaming.com, *.racetrackstreaming.com, admin.racetrackstreaming.com, stream.racetrackstreaming.com

- [x] **DNS Validation Records Generated**
  - 4 CNAME records ready for Cloudflare
  - Records can be displayed with: `make ssl-validate-dns`

- [x] **Makefile SSL Targets Created**
  - `make ssl-check` - Check certificate status and listener configuration
  - `make ssl-request-cert` - Request new certificate
  - `make ssl-validate-dns` - Display DNS records needed
  - `make ssl-create-https-listener` - Create ALB HTTPS listener
  - `make ssl-update-alb` - Configure HTTP → HTTPS redirect
  - `make ssl-setup` - Complete setup workflow

- [x] **Documentation Created**
  - `SSL_SETUP_GUIDE.md` - Complete setup guide and architecture
  - `CLOUDFLARE_DNS_VALIDATION.md` - Step-by-step Cloudflare DNS instructions
  - This checklist

---

## 📝 Phase 2: Cloudflare DNS Configuration (REQUIRES YOUR ACTION)

**Status**: PENDING - Waiting for you to add validation records to Cloudflare

### Action Items:

- [ ] **Log into Cloudflare Dashboard**
  - URL: https://dash.cloudflare.com
  - Domain: racetrackstreaming.com

- [ ] **Add 4 DNS Validation Records**
  
  | Priority | Name | Type | Value | Proxy |
  |----------|------|------|-------|-------|
  | 1 | `_ca8e511f6f3969287627790e3d988fa4.racetrackstreaming.com` | CNAME | `_1c889324b4501bca95b55ffb2c2387c0.jkddzztszm.acm-validations.aws.` | ⚪ DNS only |
  | 2 | `_ca8e511f6f3969287627790e3d988fa4.racetrackstreaming.com` | CNAME | `_1c889324b4501bca95b55ffb2c2387c0.jkddzztszm.acm-validations.aws.` | ⚪ DNS only |
  | 3 | `_29e1c2eb3de2b5e37c8bd0cd70302e19.admin.racetrackstreaming.com` | CNAME | `_c919a803146ad586ee9464f3e8fe71bd.jkddzztszm.acm-validations.aws.` | ⚪ DNS only |
  | 4 | `_18e93352c495c4b298efaeea25142c3e.stream.racetrackstreaming.com` | CNAME | `_0d80a5b757dd3cba67709dff4e088cae.jkddzztszm.acm-validations.aws.` | ⚪ DNS only |

  **CRITICAL**: Proxy status MUST be ⚪ DNS only (gray cloud), NOT 🟠 proxied (orange cloud)

- [ ] **Verify Records Are Visible**
  ```bash
  nslookup _ca8e511f6f3969287627790e3d988fa4.racetrackstreaming.com
  ```
  Should resolve successfully

- [ ] **Wait for ACM Validation** (5-15 minutes typically)
  ```bash
  make ssl-check
  ```
  Look for: `"Status": "ISSUED"` (instead of `PENDING_VALIDATION`)

**Estimated Time**: 20-30 minutes total

---

## 🔐 Phase 3: ALB HTTPS Listener Setup (AFTER VALIDATION)

**Status**: PENDING - Awaiting Phase 2 completion

### Action Items:

- [ ] **Verify Certificate is ISSUED**
  ```bash
  make ssl-check
  ```
  Must show: `"Status": "ISSUED"`

- [ ] **Create HTTPS Listener on ALB**
  ```bash
  make ssl-create-https-listener
  ```
  Output should show: `✅ HTTPS listener created` or `✅ HTTPS listener updated`

- [ ] **Verify Listener Created**
  ```bash
  make ssl-check
  ```
  Should show:
  ```
  🔗 ALB Listeners:
  ├─ Port 80 (HTTP)
  └─ Port 443 (HTTPS)
  ```

**Estimated Time**: 2-5 minutes

---

## 🔄 Phase 4: HTTP → HTTPS Redirect (AFTER LISTENER CREATED)

**Status**: PENDING - Awaiting Phase 3 completion

### Action Items:

- [ ] **Configure ALB to Redirect HTTP to HTTPS**
  ```bash
  make ssl-update-alb
  ```
  Output should show: `✅ HTTP listener now redirects to HTTPS`

- [ ] **Verify Redirect Works**
  ```bash
  # Should return 301 or 302 redirect to HTTPS
  curl -v http://admin.racetrackstreaming.com/health
  ```

**Estimated Time**: 1-2 minutes

---

## ✨ Phase 5: Testing & Verification (AFTER REDIRECT)

**Status**: PENDING - Awaiting Phase 4 completion

### Action Items:

- [ ] **Test Admin Subdomain**
  ```bash
  curl -v https://admin.racetrackstreaming.com/health
  ```
  Should return: `200 OK` with body `"healthy\n"`

- [ ] **Test Stream Subdomain**
  ```bash
  curl -v https://stream.racetrackstreaming.com/health
  ```
  Should return: `200 OK` with body `"OK"`

- [ ] **Verify Certificate Chain**
  ```bash
  openssl s_client -connect admin.racetrackstreaming.com:443 -servername admin.racetrackstreaming.com
  ```
  Look for:
  - `subject=CN = racetrackstreaming.com` (or admin.racetrackstreaming.com)
  - `verify ok` or similar
  - `subject_alt_name = admin.racetrackstreaming.com`

- [ ] **Check in Browser**
  - https://admin.racetrackstreaming.com - Should show Broadcast admin dashboard
  - https://stream.racetrackstreaming.com/hls/ - Should show HLS directory
  - Browser should show valid certificate (no warnings)

- [ ] **Monitor ECS Logs**
  ```bash
  make logs
  ```
  Should show both services healthy and accepting HTTPS traffic

**Estimated Time**: 5-10 minutes

---

## 🎯 Phase 6: Post-Launch Configuration (OPTIONAL)

**Status**: PENDING - After everything is working

### Optional Enhancements:

- [ ] **Update Cloudflare SSL Mode** (if not already done)
  - Go to Cloudflare → SSL/TLS
  - Set mode to **Full** or **Full (Strict)**
  - Enable **Always Use HTTPS**
  - Optional: Enable **HSTS** (HTTP Strict Transport Security)

- [ ] **Deploy Updated Code** (if not already deployed)
  ```bash
  make deploy
  ```
  Deploys latest Makefile and Nginx config to ECS

- [ ] **Monitor Certificate Auto-Renewal**
  - AWS ACM handles automatic renewal 60 days before expiration
  - No action needed, AWS handles it automatically

- [ ] **Setup Certificate Expiration Alerts**
  ```bash
  # AWS automatically sends emails when cert expires
  # (enabled by default for AWS ACM certificates)
  ```

- [ ] **Document SSL Configuration**
  - Created: `SSL_SETUP_GUIDE.md`
  - Created: `CLOUDFLARE_DNS_VALIDATION.md`
  - Reference these for future updates

**Estimated Time**: 10-15 minutes (optional)

---

## 🔍 Troubleshooting Checklist

### If Certificate Validation Stuck

- [ ] Check DNS records are in Cloudflare (not just added, but propagated)
- [ ] Verify proxy status is ⚪ DNS only (not 🟠 proxied)
- [ ] Confirm Cloudflare is authoritative DNS for domain
- [ ] Wait 20-30 minutes (DNS propagation can be slow)
- [ ] If still stuck after 30+ minutes, delete records and request new certificate

### If HTTPS Listener Creation Fails

- [ ] Verify certificate status is ISSUED: `make ssl-check`
- [ ] Check ALB exists: `aws elbv2 describe-load-balancers --region us-east-1`
- [ ] Verify security group allows 443: `aws ec2 describe-security-groups --group-ids sg-0693f1de9c2f66aef --region us-east-1`

### If HTTPS Returns 502 Bad Gateway

- [ ] Check ECS tasks are running: `make status`
- [ ] Verify target group health: `aws elbv2 describe-target-health --target-group-arn <arn> --region us-east-1`
- [ ] Check Nginx config in container: `make logs`
- [ ] Verify port 443 is mapped in Broadcast task definition

### If Certificate Chain is Invalid

- [ ] Cloudflare might be intercepting (check SSL mode is not Flexible)
- [ ] Browser might be caching old cert (clear browser cache)
- [ ] ALB might be using old certificate ARN (re-run `make ssl-create-https-listener`)

---

## 📊 Summary

| Phase | Status | Action | Duration |
|-------|--------|--------|----------|
| 1 | ✅ Complete | Certificate prepared | Done |
| 2 | 📝 In Progress | Add DNS to Cloudflare | 20-30 min |
| 3 | ⏳ Waiting | Create ALB listener | 2-5 min |
| 4 | ⏳ Waiting | HTTP → HTTPS redirect | 1-2 min |
| 5 | ⏳ Waiting | Test HTTPS | 5-10 min |
| 6 | ⏳ Optional | Post-launch config | 10-15 min |

**Total Time to Full SSL/TLS**: ~40-60 minutes

---

## Quick Reference Commands

```bash
# Check certificate status
make ssl-check

# View DNS records needed for Cloudflare
make ssl-validate-dns

# After adding DNS records to Cloudflare, create HTTPS listener
make ssl-create-https-listener

# Redirect HTTP to HTTPS
make ssl-update-alb

# Test HTTPS
curl -v https://admin.racetrackstreaming.com/health
curl -v https://stream.racetrackstreaming.com/health

# Monitor logs
make logs

# Check overall status
make status
```

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                           USERS (INTERNET)                          │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼ HTTPS (Cloudflare SSL Cert)
                    ┌────────────────────────────┐
                    │   Cloudflare CDN           │
                    │   (Cache + DDoS Protection)│
                    └────────────┬───────────────┘
                                 │
                                 ▼ HTTPS (AWS ACM Cert)
                    ┌────────────────────────────┐
                    │  ALB Port 443              │
                    │ (broadcast-alb)            │
                    │ Certificate: ACM           │
                    └────────────┬───────────────┘
                                 │
                                 ▼ HTTP (internal AWS VPC)
                    ┌────────────────────────────┐
                    │  ECS Broadcast Container   │
                    │  Port 80                   │
                    │  ↓ Nginx routing           │
                    │  HTTPS :443 (self-signed)  │
                    └────────────┬───────────────┘
                                 │
                    ┌────────────┴────────────┐
                    ▼                         ▼
          ┌──────────────────┐    ┌──────────────────┐
          │  Express.js      │    │  MediaMTX        │
          │  :3001 (API)     │    │  Service DNS     │
          │  (/api/*, /)     │    │  :8888 (HLS)     │
          └──────────────────┘    └──────────────────┘
```

---

## Files Created/Modified

### Created:
- `SSL_SETUP_GUIDE.md` - Complete SSL setup documentation
- `CLOUDFLARE_DNS_VALIDATION.md` - Cloudflare DNS configuration guide
- `SSL_IMPLEMENTATION_CHECKLIST.md` - This checklist

### Modified:
- `Makefile` - Added SSL targets (ssl-check, ssl-create-https-listener, ssl-update-alb, etc.)
- `broadcast-system/nginx-ssl.conf` - Added SSL architecture documentation
- `broadcast-system/docker-entrypoint.sh` - Updated startup messages with SSL info

---

## Next Step

👉 **Go to Cloudflare and add the 4 DNS validation records** (see Phase 2 above)

You can reference the exact values with:
```bash
make ssl-validate-dns
```

Once records are added and validated (5-15 minutes), continue with Phase 3.

