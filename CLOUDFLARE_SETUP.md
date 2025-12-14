# Cloudflare Setup for Production SSL

This document guides you through setting up Cloudflare for your broadcast system domain.

## Why Cloudflare?

- ✅ **Free SSL/TLS** - Industry-standard certificates (DigiCert, Google-trusted)
- ✅ **No Chrome warnings** - Proper EV-equivalent certificates
- ✅ **Reverse proxy** - Terminates SSL for you
- ✅ **DDoS protection** - Built-in security
- ✅ **Fast CDN** - Global caching
- ✅ **Auto-renewal** - Never expires

## Setup Steps

### 1. Create Cloudflare Account
- Go to https://dash.cloudflare.com
- Sign up (free tier is sufficient)
- Verify email

### 2. Add Domain to Cloudflare
- Click "Add a Site"
- Enter: `racetrackstreaming.com`
- Select "Free" plan
- Cloudflare will scan for existing DNS records

### 3. Update Nameservers (Important!)
- Cloudflare shows 2 nameservers like:
  - `nina.ns.cloudflare.com`
  - `oscar.ns.cloudflare.com`
- Go to your Route53 hosted zone: https://console.aws.amazon.com/route53/
- For the domain `racetrackstreaming.com`:
  - Update NS records to Cloudflare's nameservers
  - Delete the current Route53 NS records
  - Add Cloudflare's 2 NS records
  - Wait 5-10 minutes for DNS propagation

### 4. Add DNS Record in Cloudflare
- In Cloudflare dashboard, go to DNS records
- Click "Add record"
  - Type: `A`
  - Name: `admin` (for subdomain admin.racetrackstreaming.com)
  - IPv4 address: Get the current ECS task IP from:
    ```bash
    make broadcast-aws-get-ip
    ```
  - Proxy status: **Proxied** (orange cloud icon)
  - TTL: Auto

### 5. Enable SSL/TLS (Full Strict Mode)
- In Cloudflare dashboard, go to SSL/TLS
- Set Encryption mode to: **Full (Strict)**
- This requires your origin server (ECS task) to have a valid SSL cert
  - ✅ We already have Let's Encrypt certificate
  - Cloudflare will verify it automatically

### 6. Verify Setup
After DNS propagates (5-15 minutes):

```bash
# Test DNS resolution
nslookup admin.racetrackstreaming.com

# Test HTTPS endpoint
curl -k https://admin.racetrackstreaming.com/health

# Check certificate (should now show Cloudflare/DigiCert)
echo | openssl s_client -connect admin.racetrackstreaming.com:443 \
  -servername admin.racetrackstreaming.com 2>/dev/null | \
  openssl x509 -noout -text | grep -E "Issuer|Subject"
```

## After Each Deployment

When you deploy a new ECS task with a different IP:

```bash
# Get new task IP
make broadcast-aws-get-ip

# Update Cloudflare DNS record manually or use API
# Or just re-run the Makefile target:
make cloudflare-update-dns IP=<new-ip>
```

## Cloudflare API Setup (Optional)

If you want to automate DNS updates:

1. Get API token from Cloudflare dashboard
2. Store in `.env` or as AWS Secrets Manager secret
3. Use Cloudflare API to update records automatically

## Troubleshooting

**SSL handshake fails after setup:**
- Cloudflare requires origin server to have valid SSL cert
- ✅ We have Let's Encrypt - should work
- Check: `openssl s_client -connect <origin-ip>:443`

**DNS not resolving:**
- NS propagation takes 24-48 hours worst case
- Check current nameservers: `dig ns racetrackstreaming.com`
- Should show Cloudflare's nameservers

**Chrome still shows warning:**
- Clear browser cache and cookies
- Wait for DNS to fully propagate
- Certificate should now show "DigiCert" or "Google Trust Services"

## Costs

- **Free tier**: Perfect for this use case
  - Unlimited requests
  - 3 rules
  - Basic DDoS protection
  - Free SSL/TLS
  - No auto-renewal needed

## Security Notes

- ✅ Full (Strict) mode encrypts entire chain (browser → Cloudflare → origin)
- ✅ Cloudflare acts as reverse proxy (DDoS protection)
- ✅ Your origin server (ECS) still uses Let's Encrypt cert
- ✅ Browsers see Cloudflare's certificate (DigiCert/Google-trusted)

## Next Steps

Once Cloudflare is set up:

1. Test: https://admin.racetrackstreaming.com/dashboard
2. Should show ✅ green lock with "DigiCert" issuer
3. No Chrome warnings
4. Production-ready!
