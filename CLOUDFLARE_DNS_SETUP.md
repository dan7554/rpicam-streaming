# Cloudflare DNS Setup Guide

The deployment system is now configured to automatically set up DNS CNAME records during `make deploy-fargate` if Cloudflare credentials are provided.

## Getting Cloudflare API Credentials

### 1. Get Your API Token
1. Log in to [Cloudflare Dashboard](https://dash.cloudflare.com)
2. Go to **My Profile** → **API Tokens** (top right)
3. Click **Create Token**
4. Select **Edit zone DNS** template or create custom with:
   - Permissions: `Zone.DNS:Edit`
   - Zone Resources: Select your domain (`racetrackstreaming.com`)
5. Click **Continue to summary** → **Create Token**
6. Copy the token (shown once!)

### 2. Get Your Zone ID
1. In Cloudflare Dashboard, select your domain
2. Go to **Overview** tab (left sidebar)
3. Scroll to **API** section on the right
4. Copy **Zone ID**

## Setting Up for Deployment

### Option 1: Inline (One-time)
```bash
cd /Users/dchristiani/code/media-mtx

export CLOUDFLARE_API_TOKEN="your-api-token-here"
export CLOUDFLARE_ZONE_ID="your-zone-id-here"

make deploy-fargate
```

### Option 2: Add to Shell Profile (Persistent)
Add to your `~/.zshrc` or `~/.bash_profile`:
```bash
export CLOUDFLARE_API_TOKEN="your-api-token-here"
export CLOUDFLARE_ZONE_ID="your-zone-id-here"
```

Then reload:
```bash
source ~/.zshrc
```

### Option 3: Create Local .env File (Not for Production)
Create `/Users/dchristiani/code/media-mtx/.env.local`:
```bash
CLOUDFLARE_API_TOKEN=your-api-token-here
CLOUDFLARE_ZONE_ID=your-zone-id-here
```

Then before deployment:
```bash
cd /Users/dchristiani/code/media-mtx
source .env.local
make deploy-fargate
```

## Manual DNS Setup (If Script Fails)

If you prefer to set up DNS records manually in Cloudflare:

1. Log in to [Cloudflare Dashboard](https://dash.cloudflare.com)
2. Select `racetrackstreaming.com` domain
3. Go to **DNS** tab (left sidebar)
4. Click **Add record** twice with:

**Record 1:**
- Type: CNAME
- Name: `admin`
- Target: `broadcast-alb-1927473588.us-east-1.elb.amazonaws.com`
- TTL: 3600 (1 hour)
- Proxy: Yes (Orange Cloud)

**Record 2:**
- Type: CNAME
- Name: `stream`
- Target: `broadcast-alb-1927473588.us-east-1.elb.amazonaws.com`
- TTL: 3600 (1 hour)
- Proxy: Yes (Orange Cloud)

5. Save and wait 5-10 minutes for DNS propagation

## Testing DNS Resolution

```bash
# Check if DNS records exist
nslookup admin.racetrackstreaming.com
nslookup stream.racetrackstreaming.com

# Test HTTPS access
curl -I https://admin.racetrackstreaming.com
curl -I https://stream.racetrackstreaming.com
```

## What the Setup Script Does

The `./scripts/setup-dns-cname.sh` script:
1. ✅ Checks for `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ZONE_ID`
2. ✅ Retrieves ALB DNS name from AWS (dynamically)
3. ✅ Creates/updates CNAME records via Cloudflare API
4. ✅ Sets TTL=3600 and proxied=true for optimal performance
5. ✅ Exits gracefully if credentials missing (won't block deploy)
6. ✅ Outputs clear status messages for each record

## Script Behavior

- **With credentials**: Creates DNS records during `make deploy-fargate`
- **Without credentials**: Skips DNS setup gracefully (deployment continues)
- **Already exists**: Updates existing records with new ALB DNS

## Verification

After DNS records are set up and propagated (5-10 minutes):

```bash
make dns-info        # Show current configuration

# Or manually verify:
make dns-check       # Test domain accessibility
```

## Troubleshooting

### DNS records created but not resolving
- DNS propagation can take 5-10 minutes
- Check Cloudflare dashboard to confirm records exist
- Try: `dig admin.racetrackstreaming.com +short`

### SSL/TLS certificate errors
- Cloudflare may take time to generate SSL certificate
- Check **SSL/TLS** tab in Cloudflare dashboard
- Try HTTPS again in 5 minutes

### Script says "NXDOMAIN"
- Verify zone ID is correct (should be 32-character string)
- Confirm API token has DNS:Edit permissions
- Check that domain is active in Cloudflare

## Integration with Deployment

The DNS setup is now integrated into `make deploy-fargate`:

```
make deploy-fargate
├─ Build and deploy MediaMTX service
├─ Build and deploy Broadcast service
├─ Setup Cloudflare DNS records ← (if credentials provided)
└─ Show final status
```

If you don't provide Cloudflare credentials, everything else still deploys successfully—the domains just won't resolve until you set them up manually.
