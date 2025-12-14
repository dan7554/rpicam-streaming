# SSL/TLS Configuration Guide

## Current Status

✅ **ACM Certificate Requested**: `arn:aws:acm:us-east-1:457553343935:certificate/0c30493b-0262-455a-9773-2d077be5db53`

**Domains Covered:**
- racetrackstreaming.com
- *.racetrackstreaming.com  
- admin.racetrackstreaming.com
- stream.racetrackstreaming.com

**Status**: PENDING_VALIDATION (awaiting DNS records in Cloudflare)

---

## SSL/TLS Chain Architecture

```
Internet (HTTPS)
    ↓
Cloudflare (SSL/TLS proxy)
    ↓
ALB (Port 443 + ACM Certificate)
    ↓
ECS Broadcast Container (Port 80 → Nginx HTTPS port 443)
    ↓
├─ Nginx SSL Termination (self-signed cert fallback)
├─ Express.js Backend (Node.js)
└─ MediaMTX Proxy (via service discovery DNS)
    ↓
MediaMTX Service (Internal, no SSL needed)
```

**Key Points:**
- **Cloudflare**: Proxy/cache layer with free SSL (encrypts client → Cloudflare)
- **ALB**: Terminates Cloudflare SSL, re-encrypts to containers (ACM cert)
- **Nginx**: Optional SSL termination inside container (self-signed fallback)
- **MediaMTX**: Internal service, no public SSL exposure

---

## Setup Steps

### Step 1: Add DNS Validation Records to Cloudflare

Run this command to see the records needed:

```bash
make ssl-check
```

You'll see 4 CNAME records to add to Cloudflare DNS. Example format:

| Name | Type | Value |
|------|------|-------|
| `_ca8e511f6f3969287627790e3d988fa4.racetrackstreaming.com` | CNAME | `_1c889324b4501bca95b55ffb2c2387c0.jkddzztszm.acm-validations.aws.` |
| `_ca8e511f6f3969287627790e3d988fa4.racetrackstreaming.com` | CNAME | `_1c889324b4501bca95b55ffb2c2387c0.jkddzztszm.acm-validations.aws.` |
| `_29e1c2eb3de2b5e37c8bd0cd70302e19.admin.racetrackstreaming.com` | CNAME | `_c919a803146ad586ee9464f3e8fe71bd.jkddzztszm.acm-validations.aws.` |
| `_18e93352c495c4b298efaeea25142c3e.stream.racetrackstreaming.com` | CNAME | `_0d80a5b757dd3cba67709dff4e088cae.jkddzztszm.acm-validations.aws.` |

**Note**: The root and wildcard domains use the same validation record.

### Step 2: Wait for Validation

AWS ACM typically validates within 5-15 minutes after DNS records are in place. Monitor with:

```bash
make ssl-check
```

When status changes from `PENDING_VALIDATION` to `ISSUED`, proceed to Step 3.

### Step 3: Create HTTPS Listener on ALB

Once certificate is validated:

```bash
make ssl-create-https-listener
```

This creates a port 443 listener on your ALB and binds the ACM certificate.

### Step 4: Redirect HTTP to HTTPS

Make the ALB redirect all HTTP traffic to HTTPS:

```bash
make ssl-update-alb
```

### Step 5: Verify SSL Chain

Test HTTPS on both subdomains:

```bash
# Check certificate details
openssl s_client -connect admin.racetrackstreaming.com:443 -servername admin.racetrackstreaming.com

# Check if domains resolve and respond
curl -v https://admin.racetrackstreaming.com/health
curl -v https://stream.racetrackstreaming.com/health
```

---

## Cloudflare SSL/TLS Settings

**Important**: Your Cloudflare SSL/TLS mode must be set correctly:

- **Flexible** ❌ (Cloudflare → ALB unencrypted) - Security gap
- **Full** ✅ (Cloudflare → ALB encrypted with self-signed cert OK)
- **Full (Strict)** ⚠️ (Cloudflare → ALB must be valid cert) - May cause issues with self-signed

**Recommended**: Use **Full** mode since ALB now has valid ACM certificate.

### Update Cloudflare Settings:

1. Go to Cloudflare Dashboard → SSL/TLS
2. Set Encryption Mode to **Full** (or **Full Strict** now that you have ACM cert)
3. Ensure **Always Use HTTPS** is enabled
4. Optional: Enable **HSTS** (HTTP Strict Transport Security)

---

## Makefile Commands

### Certificate Management

```bash
# Check current certificate status
make ssl-check

# Request new certificate
make ssl-request-cert

# Display DNS validation records needed
make ssl-validate-dns ACM_CERT_ARN=arn:aws:acm:us-east-1:457553343935:certificate/0c30493b-0262-455a-9773-2d077be5db53

# Complete setup (request + show validation)
make ssl-setup
```

### ALB Listener Management

```bash
# Create HTTPS listener (requires validated certificate)
make ssl-create-https-listener

# Redirect HTTP → HTTPS
make ssl-update-alb

# Check listener status
make ssl-check
```

---

## Nginx Configuration

The Nginx config in `broadcast-system/nginx-ssl.conf` handles:

1. **Port 80 (HTTP)**
   - Health check: `GET /health` → 200 OK
   - ACME challenges: `/.well-known/acme-challenge/*` → certbot
   - Everything else: Redirect to HTTPS

2. **Port 443 (HTTPS)**
   - SSL certificates: `/etc/nginx/certs/server.crt` + `/etc/nginx/certs/server.key`
   - Routes to upstream services:
     - `/hls/*` → `mediamtx-service.broadcast-cluster.ecs.local:8888`
     - `/api/*` → `localhost:3001` (Express.js)
     - `/` → Static React files

3. **Port 8888 (ALB Health Check)**
   - Alternate health endpoint for load balancer
   - Returns 200 OK on `/health`

### Self-Signed Certificate Fallback

The `docker-entrypoint.sh` generates self-signed certificates if they don't exist:

```bash
openssl req -x509 -newkey rsa:4096 \
    -keyout /etc/nginx/certs/server.key \
    -out /etc/nginx/certs/server.crt \
    -days 365 -nodes \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost"
```

This provides SSL encryption inside the container as a fallback, though the public-facing SSL is handled by ALB + Cloudflare.

---

## Security Best Practices

1. **ALB Handles Public SSL** (ACM Certificate)
   - More secure than container-level SSL
   - AWS handles certificate renewal automatically
   - Scales better with multiple container instances

2. **Nginx Optional SSL** (Self-Signed)
   - Encrypts ALB → Container traffic
   - Protects against container network exposure
   - Not required but provides defense-in-depth

3. **Cloudflare Cache**
   - Reduces origin load
   - Adds another layer of DDoS protection
   - Can cache static content (HLS manifests)

4. **Security Group Rules**
   - ALB Security Group: Allow 80, 443 from internet
   - ECS Security Group: Allow 80, 443 from ALB security group only
   - MediaMTX: Internal only (no public exposure)

---

## Troubleshooting

### Certificate Validation Stuck

**Problem**: Certificate still in PENDING_VALIDATION after 30 minutes

**Solutions**:
1. Verify DNS records in Cloudflare (not just requested, actually DNS-resolved)
2. Check Cloudflare is proxying (orange cloud icon, not gray)
3. Request new certificate and try again
4. Ensure Cloudflare is your authoritative DNS

```bash
# Check if DNS records resolve
nslookup _ca8e511f6f3969287627790e3d988fa4.racetrackstreaming.com
```

### HTTPS Not Working After Listener Created

**Problem**: HTTPS returns 502 Bad Gateway

**Check**:
1. ECS tasks are running: `make status`
2. ALB target health is passing: `aws elbv2 describe-target-health --target-group-arn <arn>`
3. Container port 80 is accessible from ALB security group

### Mixed Content Errors

**Problem**: Browser shows mixed content warning (HTTP + HTTPS)

**Cause**: Static resources loading over HTTP inside HTTPS page

**Solution**: Ensure all resources use relative URLs or HTTPS:
- Update React build: `<link rel="stylesheet" href="/css/style.css">`
- Not: `<link rel="stylesheet" href="http://example.com/css/style.css">`

---

## Timeline

| Step | Command | Timing |
|------|---------|--------|
| 1 | `make ssl-request-cert` | Immediate (certificate ARN returned) |
| 2 | Add DNS to Cloudflare | Manual (2-3 minutes) |
| 3 | Monitor validation | 5-15 minutes (AWS validates) |
| 4 | `make ssl-create-https-listener` | Immediate (ALB updated) |
| 5 | `make ssl-update-alb` | Immediate (HTTP redirect enabled) |
| 6 | Test HTTPS | Immediate (should work) |

**Total Time**: ~15-20 minutes from start to fully functional HTTPS

---

## Next Steps

1. ✅ ACM certificate requested (done)
2. 📝 **YOU ARE HERE**: Add validation records to Cloudflare
3. ⏳ Wait for validation to complete
4. 🔐 Create HTTPS listener on ALB
5. 🔄 Configure HTTP → HTTPS redirect
6. ✅ Test both subdomains

