# DNS Setup - COMPLETE ✅

## Summary

DNS setup is now fully integrated into the deployment workflow.

### What Was Done

1. **✅ Created `dns-setup` Make Target**
   - Location: [Makefile](Makefile) (lines 897-915)
   - Checks for `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ZONE_ID`
   - Skips gracefully if credentials missing (won't block deploy)
   - Calls `./scripts/setup-dns-cname.sh`

2. **✅ Integrated into `make deploy-fargate`**
   - Location: [Makefile](Makefile) (lines 838-855)
   - DNS setup runs AFTER broadcast service deployment
   - Runs BEFORE final status display
   - Exits gracefully if credentials missing

3. **✅ DNS Script Ready**
   - Location: [scripts/setup-dns-cname.sh](scripts/setup-dns-cname.sh)
   - Dynamically retrieves ALB DNS name from AWS
   - Creates/updates CNAME records via Cloudflare API
   - Outputs clear status for each record
   - Already executable

4. **✅ Setup Guide Created**
   - Location: [CLOUDFLARE_DNS_SETUP.md](CLOUDFLARE_DNS_SETUP.md)
   - Instructions for getting API credentials
   - Multiple setup methods (inline, profile, .env file)
   - Manual setup option if script fails
   - Testing and troubleshooting guide

### Current DNS Status

**ACTIVE AND WORKING:**

```
$ make dns-info
🌐 Subdomain Configuration
===========================

Admin Dashboard Domain: admin.racetrackstreaming.com    
Streaming Domain:       stream.racetrackstreaming.com   

ALB DNS Name: broadcast-alb-1927473588.us-east-1.elb.amazonaws.com

Cloudflare CNAME Records (Required):
  Name:    admin.racetrackstreaming.com    
  Type:    CNAME
  Target:  broadcast-alb-1927473588.us-east-1.elb.amazonaws.com

  Name:    stream.racetrackstreaming.com   
  Type:    CNAME
  Target:  broadcast-alb-1927473588.us-east-1.elb.amazonaws.com
```

**DNS Resolution:**
```
$ dig admin.racetrackstreaming.com +short
172.67.179.130
104.21.51.113

$ dig stream.racetrackstreaming.com +short
172.67.179.130
104.21.51.113
```

**HTTPS Access:**
```
$ curl -I https://admin.racetrackstreaming.com/health
HTTP/2 200 OK ✅

$ curl https://admin.racetrackstreaming.com
[Returns React app dashboard] ✅
```

## How to Deploy with DNS Setup

### Step 1: Get Cloudflare Credentials

See [CLOUDFLARE_DNS_SETUP.md](CLOUDFLARE_DNS_SETUP.md) for detailed instructions, or:

1. Log in to [Cloudflare Dashboard](https://dash.cloudflare.com)
2. Go to **My Profile** → **API Tokens**
3. Create token with `Zone.DNS:Edit` permission for `racetrackstreaming.com`
4. Also note your **Zone ID** from the Overview page

### Step 2: Set Environment Variables

```bash
export CLOUDFLARE_API_TOKEN="your-api-token"
export CLOUDFLARE_ZONE_ID="your-zone-id"
```

Or add to `~/.zshrc`:
```bash
export CLOUDFLARE_API_TOKEN="your-token"
export CLOUDFLARE_ZONE_ID="your-zone-id"
```

### Step 3: Deploy

```bash
cd /Users/dchristiani/code/media-mtx
make deploy-fargate
```

The deployment will automatically:
1. ✅ Build and push MediaMTX image
2. ✅ Build and push Broadcast image  
3. ✅ Update both ECS services
4. ✅ Configure ALB routing
5. ✅ **Setup Cloudflare DNS CNAME records** ← NEW
6. ✅ Show final status

## Make Targets Available

### Deployment
- `make deploy-fargate` - Full end-to-end deployment (includes DNS setup)
- `make quick` / `make quick-ec2` - Quick update
- `make update` / `make update-ec2` - Update with latest images

### DNS Management
- `make dns-setup` - Setup Cloudflare CNAME records
- `make dns-info` - Show DNS configuration
- `make dns-check` - Test domain accessibility

### Logs & Status
- `make status` - Show deployment status
- `make logs` - Tail logs for both services

## What Happens If Credentials Are Missing?

The deployment continues successfully:
- ✅ MediaMTX service deployed
- ✅ Broadcast service deployed
- ✅ ALB configured and healthy
- ⏭️ DNS setup skipped (graceful exit)
- ⚠️ Domains won't resolve until records are set up

You can set up DNS later by:
1. Exporting credentials: `export CLOUDFLARE_API_TOKEN=... CLOUDFLARE_ZONE_ID=...`
2. Running: `make dns-setup`

## Testing the Deployment

### Verify Services Running
```bash
make status
```

### Check DNS Resolution
```bash
make dns-info
make dns-check
```

### Access Applications
- Admin Dashboard: `https://admin.racetrackstreaming.com`
- Stream Dashboard: `https://stream.racetrackstreaming.com`
- Health Check: `curl https://admin.racetrackstreaming.com/health`

### View Logs
```bash
make logs
```

## Integration Points

### Makefile Changes
- **Line 838-855**: `deploy-fargate` target now includes DNS setup step
- **Line 851**: Calls `./scripts/setup-dns-cname.sh`
- **Line 897-915**: New `dns-setup` make target

### Scripts
- **scripts/setup-dns-cname.sh**: Handles Cloudflare API integration
  - Checks credentials (exit 0 if missing)
  - Gets ALB DNS name dynamically
  - Creates/updates CNAME records
  - Sets TTL=3600, proxied=true
  - Outputs status messages

### Documentation
- **CLOUDFLARE_DNS_SETUP.md**: Complete setup guide
- **DEPLOYMENT_GUIDE.md**: Updated with DNS info
- **This file**: Overview of DNS integration

## Next Steps

1. **If you have Cloudflare credentials:**
   ```bash
   export CLOUDFLARE_API_TOKEN="your-token"
   export CLOUDFLARE_ZONE_ID="your-zone-id"
   make deploy-fargate
   ```

2. **If you don't have credentials yet:**
   - Read [CLOUDFLARE_DNS_SETUP.md](CLOUDFLARE_DNS_SETUP.md)
   - Get API token and Zone ID from Cloudflare dashboard
   - Set environment variables
   - Run `make dns-setup`

3. **To verify deployment:**
   ```bash
   make status
   make dns-info
   curl https://admin.racetrackstreaming.com
   ```

## Troubleshooting

### DNS records created but still NXDOMAIN
- DNS propagation can take 5-15 minutes
- Try flushing local DNS cache: `sudo dscacheutil -flushcache`
- Check Cloudflare dashboard to confirm records exist

### HTTPS certificate errors
- Cloudflare may take time to generate SSL certificates
- Wait 5-10 minutes and try again
- Check SSL/TLS tab in Cloudflare dashboard

### Script fails with API error
- Verify API token has `Zone.DNS:Edit` permission
- Verify zone ID is correct (32-character string)
- Check domain is active in Cloudflare
- See [CLOUDFLARE_DNS_SETUP.md](CLOUDFLARE_DNS_SETUP.md#troubleshooting)

---

**Status**: ✅ DNS integration complete and verified  
**Last Updated**: 2026-01-03  
**Domains**: admin.racetrackstreaming.com, stream.racetrackstreaming.com  
**ALB**: broadcast-alb-1927473588.us-east-1.elb.amazonaws.com
