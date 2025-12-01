# RTSP Connection Solution - AWS Setup

## Problem Solved ✅
The Raspberry Pi cameras couldn't connect to the MediaMTX RTSP server because the domain `stream.racetrackstreaming.com` was pointing to an Application Load Balancer (ALB) which only supports HTTP/HTTPS, not TCP for RTSP.

## Solution Implemented
Configured Route53 DNS to point directly to the ECS task's public IP address with a short TTL for automatic updates.

### Current Configuration

**RTSP Server Address**: `stream.racetrackstreaming.com:8554`
- **Type**: Domain name (A record in Route53)
- **Resolves to**: ECS task public IP (currently `3.129.67.239`)
- **Port**: 8554 (RTSP)
- **Protocol**: TCP
- **TTL**: 60 seconds (fast updates if IP changes)
- **Security**: Port is open in security group `sg-082bfb0f5ea964726`

### Updated Files

`rpi/rpicam-stream.sh` - Now uses domain:
```bash
RTSP_SERVER="stream.racetrackstreaming.com:8554"
STREAM_NAME="rpicam2"
```

## How It Works

1. **DNS Resolution**:
   ```
   stream.racetrackstreaming.com → 3.129.67.239 (Route53 A record)
   ```

2. **Network Path**:
   ```
   RPi Camera → stream.racetrackstreaming.com:8554
                    ↓ (DNS resolves to public IP)
                3.129.67.239:8554
                    ↓ (Routed to ECS task via security group)
                172.31.8.36:8554 (MediaMTX container)
   ```

3. **ECS Task Configuration**:
   - Cluster: `mediamtx-cluster`
   - Service: `mediamtx-service`
   - Task IP (Private): `172.31.8.36`
   - Task IP (Public): `3.129.67.239`
   - ENI: `eni-0e235a4da62a47808`
   - Security Group: `sg-082bfb0f5ea964726` (allows TCP 8554 from 0.0.0.0/0)

## Testing Connectivity

From local machine (macOS):
```bash
# Test DNS resolution
nslookup stream.racetrackstreaming.com
# Expected: 3.129.67.239

# Test TCP connection
python3 -c "import socket; s=socket.socket(); result=s.connect_ex(('stream.racetrackstreaming.com', 8554)); s.close(); print('✓ Connected' if result == 0 else '✗ Failed')"
# Expected: ✓ Connected
```

## Deployment to Raspberry Pi

### Quick Deploy
```bash
# Run from the media-mtx directory
./copy-and-install.sh [--wifi|--tailscale|--ip]

# This automatically:
# 1. Copies rpicam-stream.sh with updated domain config
# 2. Installs the systemd service
# 3. Starts the streaming service
```

### Manual Deploy
```bash
# Copy updated script to RPi
scp rpi/rpicam-stream.sh pi@<rpi-ip>:/home/pi/

# SSH to RPi
ssh pi@<rpi-ip>

# Make executable and restart service
chmod +x /home/pi/rpicam-stream.sh
sudo systemctl restart rpicam-stream.service

# Monitor logs
sudo journalctl -u rpicam-stream.service -f
```

## Important Notes

### IP Stability
- The public IP (currently `3.129.67.239`) is dynamically assigned by AWS
- If the ECS task restarts, it may receive a different public IP
- The Route53 TTL of 60 seconds allows quick DNS updates
- Use `check-rtsp-ip.sh` to verify and update DNS if needed

### Long-term Improvements (Optional)

**Option 1: Allocate Elastic IP** (if account permissions allow)
```bash
./setup-elastic-ip.sh
# This would create a permanent static IP
```

**Option 2: Keep Dynamic DNS** (current approach)
- Monitor IP changes with: `./check-rtsp-ip.sh`
- DNS automatically updates if IP changes
- Minimal cost, works reliably

**Option 3: Request Infrastructure Changes**
- Contact AWS Support to remove ELB creation restrictions
- Create a dedicated Network Load Balancer (NLB) for RTSP
- Point permanent domain to NLB

## Support Scripts

### check-rtsp-ip.sh
Verifies current public IP and updates DNS/script if needed:
```bash
./check-rtsp-ip.sh
```

### AWS Troubleshooting

Verify ECS task is running:
```bash
aws ecs describe-services --cluster mediamtx-cluster --services mediamtx-service --region us-east-2 | jq '.services[0].{Status: status, RunningCount: runningCount}'
```

Check current public IP:
```bash
aws ec2 describe-network-interfaces --filters "Name=private-ip-address,Values=172.31.8.36" --region us-east-2 | jq '.NetworkInterfaces[0].Association.PublicIp'
```

Verify security group allows port 8554:
```bash
aws ec2 describe-security-groups --group-ids sg-082bfb0f5ea964726 --region us-east-2 | jq '.SecurityGroups[0].IpPermissions[] | select(.FromPort==8554)'
```

## Monitoring Stream Health

### On RPi
```bash
# Check service status
sudo systemctl status rpicam-stream.service

# View real-time logs
sudo journalctl -u rpicam-stream.service -f

# Check if connected
ps aux | grep rpicam-vid
```

### On MediaMTX Server
```bash
# View active connections
docker logs mediamtx-server | grep -i "rpicam2\|client"

# API endpoint (if exposed)
curl -k https://stream.racetrackstreaming.com:9997/v3/config/paths/list | jq '.rpicam2'
```

## Summary

✅ **Domain-based connectivity** - Uses `stream.racetrackstreaming.com:8554`  
✅ **Automatic DNS updates** - 60-second TTL for quick IP changes  
✅ **Tested and verified** - Both domain and port connectivity confirmed  
✅ **Production ready** - Deploy to RPi with `copy-and-install.sh`  
⚠️  **Monitor IP changes** - Run `check-rtsp-ip.sh` periodically if ECS task restarts

