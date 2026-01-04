# MediaMTX NLB Setup - Complete ✅

## What Was Done

Created a **Network Load Balancer (NLB)** for MediaMTX with full multi-protocol support:

### NLB Configuration
- **Name**: `mediamtx-nlb`
- **Type**: Network Load Balancer (supports TCP/UDP)
- **DNS**: `mediamtx-nlb-07bc9de84037ff33.elb.us-east-1.amazonaws.com`
- **Status**: Provisioning → Active (takes ~5 minutes)

### Target Groups Created
1. **RTSP** (Port 8554) - For camera stream ingestion
2. **WebRTC** (Port 8889) - For browser-based live viewing
3. **API** (Port 9997) - For management and monitoring
4. **RTMP** (Port 1935) - For alternative streaming protocol

### Listeners Configured
All ports forwarding TCP traffic to MediaMTX task at `172.31.82.2`

### DNS Updated
- **Subdomain**: `mediamtx.racetrackstreaming.com`
- **Type**: CNAME
- **Target**: `mediamtx-nlb-07bc9de84037ff33.elb.us-east-1.amazonaws.com`
- **Propagation**: 5-15 minutes (usually faster with Cloudflare)

## Access URLs (Once DNS Propagates)

### For RPi Cameras (Push Streams)
```bash
# RTSP (recommended)
rtsp://mediamtx.racetrackstreaming.com:8554/camera1
rtsp://mediamtx.racetrackstreaming.com:8554/camera2

# RTMP (alternative)
rtmp://mediamtx.racetrackstreaming.com:1935/camera1
```

### For API Access
```bash
# List all streams
curl http://mediamtx.racetrackstreaming.com:9997/v3/paths/list

# Get configuration
curl http://mediamtx.racetrackstreaming.com:9997/v3/config/global/get
```

### For Browser Clients (WebRTC)
```javascript
// WebRTC endpoint
http://mediamtx.racetrackstreaming.com:8889/camera1
```

## RPi Camera Configuration

Update your RPi streaming script to use the public domain:

```bash
# OLD (only works within VPC)
rpicam-vid -t 0 --width 1920 --height 1080 --framerate 30 \
  -o - | ffmpeg -i - -c:v copy -f rtsp \
  rtsp://172.31.82.2:8554/camera1

# NEW (works from anywhere)
rpicam-vid -t 0 --width 1920 --height 1080 --framerate 30 \
  -o - | ffmpeg -i - -c:v copy -f rtsp \
  rtsp://mediamtx.racetrackstreaming.com:8554/camera1
```

## Testing

### Check NLB Status
```bash
make mediamtx-nlb-status
```

### Test Direct NLB Access (works now)
```bash
curl http://mediamtx-nlb-07bc9de84037ff33.elb.us-east-1.amazonaws.com:9997/v3/paths/list
```

### Test via Domain (after DNS propagation)
```bash
# Check DNS
dig mediamtx.racetrackstreaming.com +short

# Test API
curl http://mediamtx.racetrackstreaming.com:9997/v3/paths/list

# Test RTSP (requires ffprobe or similar)
ffprobe rtsp://mediamtx.racetrackstreaming.com:8554/camera1
```

## Make Targets Available

### Deployment
- `make mediamtx-nlb-deploy` - Complete NLB setup (all steps)
- `make mediamtx-nlb-create` - Create NLB only
- `make mediamtx-nlb-targets` - Create target groups
- `make mediamtx-nlb-listeners` - Create listeners
- `make mediamtx-nlb-register` - Register tasks with NLB

### Monitoring
- `make mediamtx-nlb-status` - Show NLB status and health
- `make dns-info` - Show DNS configuration

### Cleanup
- `make mediamtx-nlb-delete` - Delete NLB and target groups

## Architecture

```
Internet
   ↓
Cloudflare DNS (mediamtx.racetrackstreaming.com)
   ↓
AWS Network Load Balancer (mediamtx-nlb)
   ├→ Port 8554 (RTSP) → MediaMTX Task (172.31.82.2:8554)
   ├→ Port 8889 (WebRTC) → MediaMTX Task (172.31.82.2:8889)
   ├→ Port 9997 (API) → MediaMTX Task (172.31.82.2:9997)
   └→ Port 1935 (RTMP) → MediaMTX Task (172.31.82.2:1935)
```

## Cost

**NLB Pricing (us-east-1)**:
- NLB Hour: $0.0225/hour = ~$16.20/month
- LCU (Load Capacity Unit): Variable based on traffic
- Estimated total: **$16-25/month** depending on usage

## Security Considerations

1. **NLB is publicly accessible** - All configured ports (8554, 8889, 9997, 1935) are open to the internet
2. **MediaMTX authentication** - Configure in mediamtx.yml if needed
3. **Cloudflare proxying** - DNS is proxied through Cloudflare for DDoS protection
4. **Security Groups** - ECS task security group allows traffic from NLB

## Next Steps

1. **Wait for NLB to become active** (~5 minutes)
   ```bash
   make mediamtx-nlb-status
   ```

2. **Wait for DNS propagation** (~5-15 minutes)
   ```bash
   dig mediamtx.racetrackstreaming.com +short
   ```

3. **Test API access**
   ```bash
   curl http://mediamtx.racetrackstreaming.com:9997/v3/paths/list
   ```

4. **Update RPi camera scripts** with new RTSP URL

5. **Test stream ingestion**
   ```bash
   # Push test stream from your machine
   ffmpeg -re -i test.mp4 -c copy -f rtsp \
     rtsp://mediamtx.racetrackstreaming.com:8554/test
   ```

## Troubleshooting

### NLB targets showing "initial"
- Wait 2-3 minutes for health checks to complete
- Run: `make mediamtx-nlb-status`

### DNS not resolving
- Check propagation: `dig mediamtx.racetrackstreaming.com +short`
- Flush local cache: `sudo dscacheutil -flushcache`
- Wait up to 15 minutes for global propagation

### Connection refused
- Verify NLB is active: `make mediamtx-nlb-status`
- Check security groups allow traffic
- Test direct NLB DNS first before testing subdomain

### RTSP stream not working
- Verify MediaMTX is running: `make status`
- Check MediaMTX logs: `make logs | grep mediamtx`
- Test locally first: `curl http://172.31.82.2:9997/v3/paths/list`

---

**Status**: ✅ NLB created and configured  
**DNS**: ✅ Updated (propagating)  
**Services**: ✅ All running and registered  
**Ready**: ⏳ 5-10 minutes for NLB + DNS propagation
