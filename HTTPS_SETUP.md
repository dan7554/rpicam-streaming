# HTTPS Setup for Admin Dashboard

Your broadcast system is now deployed and accessible via HTTP. To enable HTTPS, we'll use Cloudflare's free SSL/TLS service.

## Quick Summary

✅ **Current Status:**
- Application running: `http://broadcast-alb-525661146.us-east-1.elb.amazonaws.com/`
- Health check: Returns 200 OK ✓
- ALB targets: 1 healthy ✓
- Express server: Running on port 3001 ✓
- Nginx: Configured and proxying correctly ✓

❌ **Missing:**
- HTTPS on the ALB (needed for `https://admin.racetrackstreaming.com`)
- DNS nameservers pointing to Cloudflare

## Solution: Cloudflare Flexible SSL

Cloudflare provides **free HTTPS** using a "Flexible" SSL setup:
- Your browser connects to Cloudflare via HTTPS (Cloudflare provides the certificate)
- Cloudflare connects to your ALB via HTTP (port 80)
- No certificate management needed on your end

## Setup Option 1: Automated (If you have Cloudflare API credentials)

```bash
# Set your Cloudflare credentials
export CLOUDFLARE_API_TOKEN="your-token-from-dash.cloudflare.com/profile/api-tokens"
export CLOUDFLARE_ZONE_ID="your-zone-id-from-cloudflare-dashboard"

# Run automated setup
./setup-cloudflare-auto.sh
```

## Setup Option 2: Manual (Recommended - Step-by-Step)

Run this script to see detailed instructions:
```bash
./setup-cloudflare-https.sh
```

Or follow these steps manually:

### Step 1: Add Domain to Cloudflare (if not already done)
1. Go to https://dash.cloudflare.com
2. Click "Add a Site"
3. Enter: `racetrackstreaming.com`
4. Select "Free" plan
5. Complete the domain setup

### Step 2: Create DNS Record in Cloudflare
1. Go to **DNS → Records**
2. Click **Add record**
3. Fill in:
   - **Type:** A
   - **Name:** admin
   - **IPv4 address:** `broadcast-alb-525661146.us-east-1.elb.amazonaws.com`
   - **Proxy status:** ☁️ **Proxied** (orange cloud - IMPORTANT!)
   - **TTL:** Auto
4. Click **Save**

### Step 3: Update Route53 Nameservers
1. Go to AWS Route53 Console
2. Click **Hosted zones**
3. Select **racetrackstreaming.com**
4. Note the current NS records (you can revert if needed)
5. In Cloudflare, you'll see 2 nameservers like:
   - `nina.ns.cloudflare.com`
   - `oscar.ns.cloudflare.com`
6. Replace your Route53 NS records with these Cloudflare nameservers
7. **Wait 5-15 minutes** for DNS propagation

### Step 4: Enable Flexible SSL in Cloudflare
1. Go to **SSL/TLS → Overview**
2. Set encryption mode to: **Flexible**
3. (This is already the default, but verify it)

### Step 5: Verify Setup
After DNS propagates (5-15 minutes), test:

```bash
# Check DNS is pointing to Cloudflare
nslookup admin.racetrackstreaming.com
# Should show Cloudflare IPs (like 1.2.3.4), not AWS IPs

# Test HTTPS endpoint
curl -I https://admin.racetrackstreaming.com/
# Should return 301 redirect

# Check certificate
echo | openssl s_client -connect admin.racetrackstreaming.com:443 2>/dev/null | grep Issuer
# Should show Cloudflare or DigiCert
```

## Testing in Your Browser

Once DNS propagates:
1. Open Chrome/Firefox
2. Go to: https://admin.racetrackstreaming.com
3. Should see:
   - 🔒 Green lock icon (secure)
   - "Cloudflare" or "DigiCert" certificate
   - 301 redirect to HTTPS
   - No warnings

## Troubleshooting

**DNS still not updated after 15 minutes:**
```bash
# Clear local DNS cache
sudo dscacheutil -flushcache  # macOS
# or
ipconfig /flushdns             # Windows
# or
sudo systemctl restart systemd-resolved  # Linux

# Then retry:
nslookup admin.racetrackstreaming.com
```

**HTTPS shows Cloudflare error:**
1. Verify ALB is responding:
   ```bash
   curl -v http://broadcast-alb-525661146.us-east-1.elb.amazonaws.com/
   ```
2. Check Cloudflare DNS record points to ALB DNS (not IP)
3. Verify SSL/TLS is set to "Flexible" (not Full Strict)

**Certificate shows wrong domain:**
1. Wait a few more minutes for Cloudflare to issue certificate
2. Or go to **SSL/TLS → Edge certificates** and check status

## Architecture After HTTPS Setup

```
Browser (Chrome/Firefox)
    ↓ HTTPS
Cloudflare (dash.cloudflare.com)
    ↓ HTTP (port 80)
ALB (broadcast-alb-525661146.us-east-1.elb.amazonaws.com)
    ↓
Nginx (ports 80/443, 8888)
    ↓
Express Server (port 3001)
    ↓
React Admin Dashboard
```

## Important Notes

- ✅ Cloudflare free plan is sufficient for this use case
- ✅ No certificate renewal needed (Cloudflare handles it)
- ✅ No config changes needed on your ALB or application
- ⚠️ Nameserver change is required (Step 3) - Route53 becomes secondary
- ⚠️ Changing nameservers affects **all** subdomains (rtsp, mediamtx, etc.)

## Next Steps (Optional)

1. **Increase TTL for faster updates:**
   - In Cloudflare DNS settings, change TTL from Auto to 3600
   
2. **Enable HTTPS redirect (Page Rule):**
   - Go to **Rules → Page Rules**
   - Create rule: `https://admin.racetrackstreaming.com/*`
   - Action: **Always Use HTTPS**

3. **Enable additional security:**
   - Go to **Security → WAF**
   - Enable recommended rules

4. **Monitor performance:**
   - Go to **Analytics & Logs**
   - Check traffic, security events, etc.

## Questions?

- Cloudflare docs: https://developers.cloudflare.com/
- AWS Route53 docs: https://docs.aws.amazon.com/route53/
- SSL/TLS setup guide: ./CLOUDFLARE_SETUP.md

---

**Your admin dashboard is ready to go live with HTTPS! 🎉**
