# SSL/TLS Configuration - Complete Index

## Quick Start

You have 4 comprehensive guides to walk you through SSL/TLS setup from start to finish:

### 1. **SSL_SETUP_GUIDE.md** 📚
Complete overview of the SSL/TLS architecture and setup process.

**Topics Covered:**
- Architecture diagram (Cloudflare → ALB → ECS → Nginx → Apps)
- Step-by-step setup instructions
- Cloudflare SSL/TLS settings
- Nginx configuration explanation
- Security best practices
- Timeline estimates

**When to read**: First, to understand the full picture

---

### 2. **CLOUDFLARE_DNS_VALIDATION.md** 🔐
Detailed step-by-step guide for adding validation records to Cloudflare.

**Topics Covered:**
- DNS records needed (exact names and values)
- How to add records to Cloudflare dashboard
- Verification steps
- Monitoring validation progress
- Troubleshooting if validation fails
- Existing vs validation records

**When to read**: Before adding DNS records to Cloudflare

**Action Required**: You must manually add 4 CNAME records to Cloudflare DNS

---

### 3. **SSL_IMPLEMENTATION_CHECKLIST.md** ✅
Phase-by-phase checklist with all action items and commands.

**Topics Covered:**
- 6 phases (Certificate prep through post-launch)
- Specific commands for each phase
- Time estimates per phase
- Troubleshooting checklist
- Quick reference commands
- Timeline summary

**When to read**: To track progress through all phases

---

### 4. **SSL_TESTING_GUIDE.md** 🧪
Comprehensive testing procedures to verify SSL/TLS is working.

**Topics Covered:**
- Commands to test after validation
- Expected outputs for each test
- Browser testing instructions
- Certificate chain verification
- Performance testing (optional)
- Common issues and solutions

**When to read**: After HTTPS listener is created, before going live

---

## Makefile Commands

All SSL/TLS operations are automated through Makefile targets:

```bash
# Check certificate status and ALB listeners
make ssl-check

# View DNS validation records needed in Cloudflare
make ssl-validate-dns

# After DNS records are added, monitor validation
make ssl-check  # Check status, should change to "ISSUED"

# Create HTTPS listener on ALB (requires validated certificate)
make ssl-create-https-listener

# Redirect HTTP traffic to HTTPS
make ssl-update-alb

# Test both subdomains
curl -v https://admin.racetrackstreaming.com/health
curl -v https://stream.racetrackstreaming.com/health

# Monitor logs
make logs

# Check overall system status
make status
```

---

## Current Status

### ✅ Completed

- [x] AWS ACM Certificate Requested
  - ARN: `arn:aws:acm:us-east-1:457553343935:certificate/0c30493b-0262-455a-9773-2d077be5db53`
  - Status: **PENDING_VALIDATION** (awaiting Cloudflare DNS records)
  - Domains: racetrackstreaming.com, *.racetrackstreaming.com, admin.racetrackstreaming.com, stream.racetrackstreaming.com

- [x] Makefile SSL targets created (5 targets)
- [x] Nginx configuration updated with SSL architecture docs
- [x] Docker entrypoint enhanced with SSL messages
- [x] Comprehensive documentation (4 guides)

### 📝 In Progress (You are here)

- [ ] Add 4 DNS validation records to Cloudflare DNS
  - Use: `make ssl-validate-dns` to see records
  - Go to: https://dash.cloudflare.com → DNS
  - **CRITICAL**: Set proxy status to ⚪ DNS only (not 🟠 proxied)

### ⏳ Pending (After DNS validation)

- [ ] Wait for ACM validation (5-15 minutes)
  - Monitor with: `make ssl-check`
  - Look for: Status changes from PENDING_VALIDATION → ISSUED

- [ ] Create HTTPS listener on ALB
  - Run: `make ssl-create-https-listener`
  - Estimated time: 2-5 minutes

- [ ] Redirect HTTP → HTTPS
  - Run: `make ssl-update-alb`
  - Estimated time: 1-2 minutes

- [ ] Test HTTPS endpoints
  - Use: SSL_TESTING_GUIDE.md commands
  - Estimated time: 5-10 minutes

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│                     USERS (INTERNET)                         │
└─────────────────────────┬──────────────────────────────────┘
                          │ HTTPS (Port 443)
                          │ Certificate: Cloudflare
                          ▼
                    ┌──────────────┐
                    │  Cloudflare  │
                    │  CDN + Cache │
                    │  + DDoS      │
                    └──────┬───────┘
                           │ HTTPS (Port 443)
                           │ Certificate: AWS ACM
                           ▼
                    ┌──────────────────────┐
                    │  ALB (broadcast-alb) │
                    │  Port 80  (HTTP)     │
                    │  Port 443 (HTTPS) ← TO CREATE
                    └──────┬───────────────┘
                           │ HTTP (internal VPC)
                           ▼
                    ┌──────────────────────────┐
                    │  ECS Broadcast Container │
                    │  Port 80 (Nginx)         │
                    └──────┬───────────────────┘
                           │ HTTPS (self-signed)
                           ▼
                    ┌────────────────┐
                    │    Nginx       │
                    │    Port 443    │
                    └────┬───────┬──┬┘
         ┌────────────────┘       │  └────────────┐
         ▼                        ▼               ▼
    ┌─────────┐          ┌──────────────┐   ┌─────────┐
    │Express  │          │  MediaMTX    │   │ Static  │
    │:3001    │          │  :8888 (HLS) │   │ React   │
    │(/api/*) │          │   (service   │   │ Files   │
    │         │          │  discovery)  │   │         │
    └─────────┘          └──────────────┘   └─────────┘
```

---

## Files Created/Modified

### New Documentation (4 files)
- `SSL_SETUP_GUIDE.md` - Complete architecture and setup guide
- `CLOUDFLARE_DNS_VALIDATION.md` - Step-by-step Cloudflare DNS instructions
- `SSL_IMPLEMENTATION_CHECKLIST.md` - Phase-by-phase implementation checklist
- `SSL_TESTING_GUIDE.md` - Comprehensive testing procedures
- `SSL_TLS_CONFIGURATION_INDEX.md` - This file

### Modified Configuration Files
- `Makefile` - Added 5 SSL/TLS targets (ssl-check, ssl-validate-dns, ssl-create-https-listener, ssl-update-alb, ssl-setup)
- `broadcast-system/nginx-ssl.conf` - Added SSL/TLS architecture diagram in comments
- `broadcast-system/docker-entrypoint.sh` - Enhanced startup messages with SSL chain info

---

## DNS Records You Need to Add

Run this to see the exact records:

```bash
make ssl-validate-dns
```

You'll get something like:

```
📌 Domain: racetrackstreaming.com
   Name:  _ca8e511f6f3969287627790e3d988fa4.racetrackstreaming.com.
   Type:  CNAME
   Value: _1c889324b4501bca95b55ffb2c2387c0.jkddzztszm.acm-validations.aws.

📌 Domain: *.racetrackstreaming.com
   Name:  _ca8e511f6f3969287627790e3d988fa4.racetrackstreaming.com.
   Type:  CNAME
   Value: _1c889324b4501bca95b55ffb2c2387c0.jkddzztszm.acm-validations.aws.

📌 Domain: admin.racetrackstreaming.com
   Name:  _29e1c2eb3de2b5e37c8bd0cd70302e19.admin.racetrackstreaming.com.
   Type:  CNAME
   Value: _c919a803146ad586ee9464f3e8fe71bd.jkddzztszm.acm-validations.aws.

📌 Domain: stream.racetrackstreaming.com
   Name:  _18e93352c495c4b298efaeea25142c3e.stream.racetrackstreaming.com.
   Type:  CNAME
   Value: _0d80a5b757dd3cba67709dff4e088cae.jkddzztszm.acm-validations.aws.
```

**IMPORTANT**: Set proxy status to ⚪ **DNS only** (gray cloud), NOT 🟠 **proxied** (orange cloud)

---

## Quick Command Reference

### Setup Phase
```bash
# 1. View records needed
make ssl-validate-dns

# 2. Add records to Cloudflare (manual in dashboard)
# Go to: https://dash.cloudflare.com → racetrackstreaming.com → DNS

# 3. Monitor validation (run every minute)
make ssl-check

# 4. Create HTTPS listener (after status changes to ISSUED)
make ssl-create-https-listener

# 5. Redirect HTTP → HTTPS
make ssl-update-alb
```

### Testing Phase
```bash
# Test admin subdomain
curl -v https://admin.racetrackstreaming.com/health

# Test stream subdomain
curl -v https://stream.racetrackstreaming.com/health

# Check certificate details
echo | openssl s_client -connect admin.racetrackstreaming.com:443 \
  -servername admin.racetrackstreaming.com 2>/dev/null | openssl x509 -noout -text

# Monitor logs
make logs

# Check status
make status
```

---

## Timeline

| Step | Action | Duration | Status |
|------|--------|----------|--------|
| 1 | View DNS records | 1 min | ✅ Done |
| 2 | Add to Cloudflare | 3-5 min | 📝 You are here |
| 3 | Wait for validation | 5-15 min | ⏳ Next |
| 4 | Create HTTPS listener | 2-5 min | ⏳ Next |
| 5 | HTTP → HTTPS redirect | 1-2 min | ⏳ Next |
| 6 | Test HTTPS | 5-10 min | ⏳ Next |
| **Total** | | **17-40 min** | |

---

## Next Step

👉 **Run this command to get the DNS records:**

```bash
make ssl-validate-dns
```

Then:

1. Go to https://dash.cloudflare.com → DNS
2. Add the 4 CNAME records shown (proxy status: ⚪ DNS only)
3. Wait 5-15 minutes for validation
4. Run `make ssl-check` to confirm status changed to ISSUED
5. Then run `make ssl-create-https-listener`
6. Then run `make ssl-update-alb`
7. Test with commands from SSL_TESTING_GUIDE.md

---

## Support Documents

- **SSL_SETUP_GUIDE.md** - Understanding the architecture
- **CLOUDFLARE_DNS_VALIDATION.md** - How to add DNS records
- **SSL_IMPLEMENTATION_CHECKLIST.md** - Step-by-step checklist
- **SSL_TESTING_GUIDE.md** - How to test after setup
- **Makefile** - Automated commands for all SSL operations

---

## Key Concepts

### ACM Certificate
- Automatically managed by AWS
- Automatically renewed 60 days before expiration
- Valid for 1 year (13 months)
- Covers: racetrackstreaming.com, *.racetrackstreaming.com, admin, stream

### ALB HTTPS Listener
- Terminates public SSL/TLS
- Uses AWS ACM certificate
- Port 443 (to be created)
- Redirects HTTP to HTTPS

### Nginx SSL (Optional)
- Self-signed certificate for internal use
- Defense-in-depth encryption
- Not required (ALB handles public SSL)
- Can be enhanced with AWS Secrets Manager

### Cloudflare
- Cache and CDN layer
- DDoS protection
- Handles client-facing SSL
- We use "Full" mode (client → Cloudflare → ALB encrypted)

---

## Security Checklist

- [ ] ACM certificate covers all domains
- [ ] ALB HTTPS listener created and listening
- [ ] HTTP redirects to HTTPS
- [ ] Cloudflare SSL mode set to "Full"
- [ ] Security group allows 443 from internet
- [ ] ECS target group health is "healthy"
- [ ] Nginx proxies correctly to MediaMTX
- [ ] All API endpoints accessible over HTTPS
- [ ] HLS streams accessible over HTTPS
- [ ] Certificate chain validates in browsers

---

## Troubleshooting Resources

See **SSL_IMPLEMENTATION_CHECKLIST.md** section "Troubleshooting Checklist" for:
- Certificate validation stuck
- HTTPS listener creation fails
- 502 Bad Gateway errors
- Invalid certificate chain

See **SSL_TESTING_GUIDE.md** section "Troubleshooting Tests" for:
- Certificate chain validation
- Target health checks
- Mixed content issues
- Performance testing

---

## Questions?

All answers are in the documentation files:

1. **How does SSL/TLS work?** → Read: SSL_SETUP_GUIDE.md
2. **How do I add DNS records?** → Read: CLOUDFLARE_DNS_VALIDATION.md
3. **What's my next step?** → Read: SSL_IMPLEMENTATION_CHECKLIST.md
4. **How do I test it?** → Read: SSL_TESTING_GUIDE.md
5. **What commands do I run?** → Check: Makefile targets or this file's "Quick Command Reference"

