# Camera Power Management System

Remote camera control via Tailscale from EC2 server.

## Infrastructure

### EC2 Server
- **Public IP**: 100.23.149.218
- **Instance**: `i-08bc8954c7e2a0405` (us-west-2)
- **SSH Key**: `~/.ssh/racetrack-streaming.pem`
- **Tailscale**: Installed and connected

### Pi Cameras

| Name | Tailscale IP | Hardware | Notes |
|------|-------------|----------|-------|
| rpicam3 | 100.95.47.104 | Pi 5 | Primary camera |
| rpicam1 | 100.86.40.47 | Pi Zero 2W | Secondary |

**Credentials**: `dan7554` / `!Dan1007554`

## Battery Performance

Tested on Pi 5 with power bank:
- **Streaming**: ~9.2% drain/hour (~11 hours runtime)
- **Sleep mode**: ~4.3% drain/hour (~23 hours runtime)

## Camera Control Actions

Available via debug page (`/debug.html`) or API:

| Action | Description |
|--------|-------------|
| `sleep` | Stop streaming, stop health-agent, set CPU to powersave |
| `stream` | Start health-agent, start streaming, set CPU to ondemand |
| `restart` | Restart rpicam-stream service |
| `reboot` | Standard reboot |
| `reboot-cli` | Set default to CLI (multi-user.target), then reboot |
| `reboot-gui` | Set default to GUI (graphical.target), then reboot |

## API Endpoints

```
GET  /api/camera/list          # List cameras with online status
POST /api/camera/control       # {"camera": "rpicam3", "action": "sleep"}
GET  /api/debug/tailscale      # Tailscale status
POST /api/debug/tailscale/up   # Start Tailscale auth
```

## Key Files

- `internal/api/handler.go` - Camera control handlers (~lines 1050-1150)
- `internal/config/config.go` - Tailscale device lookup with caching
- `web/debug.html` - Admin UI with camera controls
- `rpi/power-mode.sh` - Local script for Mac-based control
- `deploy/systemd/stream-server.service` - Server systemd unit (has CAMERA_USER/CAMERA_PASS env vars)

## Code Architecture

### config.go - Tailscale Integration

```go
type TailscaleDevice struct {
    Name   string
    IP     string
    Online bool
}
```

- `GetCameraIP(name)` - Returns IP for a specific camera
- `GetAllCameraIPs()` - Returns all cameras with online status
- `queryTailscale()` - Parses `tailscale status --json`
- Results cached for 10 seconds

### handler.go - Camera Control

Sleep mode stops:
- `rpicam-stream` service
- `health-agent` service
- Sets CPU governor to `powersave`

Stream mode starts:
- `health-agent` service (first)
- `rpicam-stream` service
- Sets CPU governor to `ondemand`

Reboot-CLI command:
```bash
systemctl set-default multi-user.target
reboot
```

Reboot-GUI command:
```bash
systemctl set-default graphical.target
reboot
```

### debug.html - UI Features

- Camera cards with Sleep/Stream/Restart/Reboot buttons
- Secondary row with Reboot→CLI and Reboot→GUI buttons
- Visual feedback: ✓/✗ icons, color coding, green flash on success
- 15-second auto-clear of status messages
- Offline cameras show red "offline" and have disabled buttons
- "All Cameras" card for batch operations
- Tailscale status section with auth URL display when needed

CSS classes:
- `.btn-sleep` - Purple (#7c4dff)
- `.btn-stream` - Green (#4caf50)
- `.btn-restart` - Orange (#ff9800)
- `.btn-danger` - Red (#e53935)
- `.btn-secondary` - Gray (#555)

## Deployment

```bash
# Full deploy
make deploy
scp -i ~/.ssh/racetrack-streaming.pem web/debug.html ubuntu@100.23.149.218:/opt/racetrack/web/
ssh -i ~/.ssh/racetrack-streaming.pem ubuntu@100.23.149.218 "sudo systemctl restart stream-server"

# Quick one-liner
cd /Users/dchristiani/code/media-mtx && go build ./... && make deploy && \
  scp -i ~/.ssh/racetrack-streaming.pem web/debug.html ubuntu@100.23.149.218:/opt/racetrack/web/ && \
  ssh -i ~/.ssh/racetrack-streaming.pem ubuntu@100.23.149.218 "sudo systemctl restart stream-server"
```

## Sleep Mode Commands (on Pi)

```bash
# Enter sleep mode
systemctl stop rpicam-stream health-agent
echo powersave | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# Enter stream mode
systemctl start health-agent rpicam-stream
echo ondemand | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

## Tailscale Integration

The server queries `tailscale status --json` to:
- Discover camera IPs dynamically
- Detect online/offline status (checks `Online` field in JSON)
- Cache results for 10 seconds

Cameras are identified by hostname prefix `rpicam`.

## Troubleshooting

### Tailscale Auth Required
If the debug page shows an auth URL, click it or run:
```bash
ssh -i ~/.ssh/racetrack-streaming.pem ubuntu@100.23.149.218 "sudo tailscale up"
```

### Camera Shows Offline
1. Check Pi is powered on
2. SSH directly: `ssh dan7554@100.95.47.104`
3. Check Tailscale on Pi: `tailscale status`

### Commands Not Working
Check server logs:
```bash
ssh -i ~/.ssh/racetrack-streaming.pem ubuntu@100.23.149.218 "journalctl -u stream-server -f"
```
