# Media-MTX: Multi-Camera Live Streaming Platform

A Go-based streaming system combining **MediaMTX**, **GStreamer**, and a custom RTSP switching proxy for live broadcast to YouTube — with zero-gap camera switching, timing overlays, logo overlays, ad breaks, and browser-based commentary mixing.

## Features

- **Zero-gap camera switching** — RTSP proxy bridge with keyframe sync and RTP timestamp rewriting
- **GStreamer pipelines** — video encoding, audio mixing, and overlay composition
- **Browser-based commentary** — WHIP publish from the web UI, mixed via GStreamer audiomixer
- **Race timing overlays** — MYLAPS/SpeedHive live timing rendered as a PNG timing tower with 6 format options
- **Logo overlays** — Upload PNG logos to top-right and bottom-right corners with per-logo opacity, offset, and scale
- **Ad break system** — Upload videos, auto-transcode, and play ad breaks mid-stream
- **Flag status indicators** — Red, Yellow, Green, and Checkered flag overlay
- **Custom overlay title** — Override the SpeedHive session name with a custom title
- **Overlay styling** — Full custom styling: colors, sizing, column widths, element positioning, opacity
- **SpeedHive Results API** — Supports both live timing and `/sessions/{id}` result URLs
- **Fleet management** — Remote monitoring of Pi cameras with CPU temp, uptime, and Starlink stats
- **Multi-camera viewer** — Dedicated `/viewer` page with full-screen camera grid and click-to-switch
- **Kick commentator** — Remove commentators from slots via the admin UI
- **Multi-destination output** — YouTube RTMP, local RTMP, WebRTC preview
- **Low-latency preview** — WebRTC with HLS fallback, live output preview
- **Debug tools** — Remote service restart, log viewer
- **MediaMTX watchdog** — Auto-detects and restarts stuck WebRTC sessions
- **Persistent UI config** — Settings survive restarts and are shared across browser sessions
- **AWS deployment** — Terraform infrastructure-as-code (ALB, NLB, EC2)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Pi Cameras (RTMP)          Browser Commentary (WHIP)       │
│  ┌────────┐ ┌────────┐     ┌─────────────┐                 │
│  │ rpicam2│ │ rpicam3│     │ Commentator │                  │
│  └───┬────┘ └───┬────┘     └──────┬──────┘                  │
│      │ RTMP     │ RTMP            │ WebRTC/WHIP             │
└──────┼──────────┼─────────────────┼─────────────────────────┘
       ▼          ▼                 ▼
┌─────────────────────────────────────────────────────────────┐
│              MediaMTX  [:8554 RTSP, :1935 RTMP, :8889 WebRTC]│
│  Paths: cam2, cam3, live-output, live-preview,              │
│         commentary-1, commentary-2                          │
└──────┬──────────┬─────────────────┬─────────────────────────┘
       │          │                 │
       ▼          ▼                 │
┌──────────────────────┐            │
│  Bridge Proxy :8555  │            │
│  • Reads all cameras │            │
│  • Atomic switching  │            │
│  • Keyframe sync     │            │
│  • RTP timestamp     │            │
│    rewriting         │            │
└──────────┬───────────┘            │
           ▼                        ▼
┌─────────────────────────────────────────────────────────────┐
│                    GStreamer Pipeline                        │
│  ┌──────────┐  ┌───────────┐  ┌──────────┐                 │
│  │ Bridge   │  │ Overlay   │  │ Comment. │                  │
│  │ Video    │→ │ Compositor│→ │ Audio    │→ flvmux → RTMP   │
│  │ + Audio  │  │ (PNG)     │  │ Mixer    │    ↓             │
│  └──────────┘  │ + Logos   │  └──────────┘  YouTube         │
│                └───────────┘                                │
│  Also outputs → RTSP live-preview (WebRTC to browser)       │
│  Ad breaks → swap video source to transcoded ad files       │
└─────────────────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│                      Web UI :8080                           │
│  • Camera preview grid (WebRTC / HLS) with toggle           │
│  • One-click camera switching                               │
│  • Go Live / Stop controls with YouTube key                 │
│  • MYLAPS overlay controls (format, scale, rows, title)     │
│  • Logo overlays (upload, opacity, offset per corner)       │
│  • Ad break system (upload, transcode, multi-select play)   │
│  • Flag controls (Red, Yellow, Green, Checkered, Clear)     │
│  • Commentary: 2 slots with per-mic + camera volume + kick  │
│  • Live output preview (WebRTC, pause/resume)               │
│  • /viewer — full-screen multi-camera grid                  │
│  • /fleet — Pi camera fleet monitoring + Starlink stats     │
│  • /debug — service restart + log viewer                    │
└─────────────────────────────────────────────────────────────┘
```

### Zero-Gap Switching

1. Bridge proxy connects to all camera RTSP streams simultaneously
2. On switch, bridge sets `needsKeyframe = true` and drops packets until an H.264 IDR frame arrives
3. RTP timestamps and sequence numbers are rewritten to maintain continuity — no gaps or desync in the output
4. GStreamer reads from a single bridge output stream (`rtsp://localhost:8555/stream`)

### Commentary Mixing

1. Commentator clicks "Join" in the web UI → browser captures mic via `getUserMedia`
2. Audio is published to MediaMTX via WHIP (WebRTC, Opus codec)
3. GStreamer pulls commentary streams from `rtsp://localhost:8554/commentary-{1,2}`
4. `audiomixer` blends camera audio + commentary audio with independent volume controls
5. Mixed audio is encoded to AAC and muxed into the RTMP output

### Timing Overlay Formats

| Format | Description |
|--------|-------------|
| `full` | Position, car number, full name, laps, gap |
| `condensed` | Position, car number, "J. Doe", gap (narrow tower) |
| `condensed-nogap` | Same as condensed without gap column |
| `short` | Position, car number, 3-letter last name, gap |
| `short-nogap` | Same as short without gap column |
| `minimal` | Position, car number, gap (ultra-compact) |

Scale can be set to any decimal value (e.g. 1.5, 2.0) to control overlay size on the 1920×1080 output.

## Directory Structure

```
media-mtx/
├── cmd/
│   ├── server/main.go           # Entry point
│   └── overlay-preview/main.go  # Overlay preview/design server
├── internal/
│   ├── ads/ads.go               # Ad break manager (upload, transcode, playback)
│   ├── api/handler.go           # HTTP API + reverse proxies (HLS, WebRTC)
│   ├── bridge/bridge.go         # RTSP switching proxy with timestamp rewriting
│   ├── config/config.go         # Environment-based configuration
│   ├── overlay/overlay.go       # MYLAPS timing tower renderer (PNG)
│   ├── switcher/
│   │   ├── switcher.go          # Pipeline lifecycle, camera switching, logos
│   │   └── pipeline_test.go     # Pipeline unit tests
│   └── uiconfig/uiconfig.go    # Persistent UI config store
├── web/
│   ├── index.html               # UI: cameras, controls, overlay, logos, ads, commentary
│   ├── app.js                   # WebRTC/HLS playback, API calls, WHIP publish
│   ├── style.css                # Dark theme
│   ├── viewer.html              # Full-screen multi-camera viewer
│   └── fleet.html               # Pi camera fleet dashboard
├── deploy/
│   ├── mediamtx-aws.yml         # MediaMTX production config
│   ├── systemd/                 # systemd units for EC2
│   └── terraform/               # Full AWS infrastructure (VPC, EC2, ALB, NLB, ACM)
├── rpi/
│   ├── rpicam-stream.sh         # Pi camera streaming script (RTMP + SRT)
│   ├── rpicam-stream.service    # systemd unit
│   ├── deploy.sh                # Deploy script for Pi cameras
│   └── cellular/                # 5G modem setup scripts
├── scripts/
│   ├── start.sh                 # Start all services
│   ├── fake-streams.sh          # Test pattern streams
│   ├── start-mediamtx.sh
│   ├── start-server.sh
│   └── start-tunnels.sh         # SSH tunnels for Pi cameras
├── mediamtx.yml                 # MediaMTX local dev config
├── Makefile                     # Build, test, deploy targets
└── go.mod
```

## Quick Start

### Prerequisites

- Go 1.25+
- GStreamer 1.24+ with plugins: base, good, bad, ugly, libav
- [MediaMTX](https://github.com/bluenviron/mediamtx) binary in `./bin/`

### Local Development

```bash
# Start everything (MediaMTX + fake test streams + server)
make run

# Or start components individually
./scripts/start-mediamtx.sh
./scripts/fake-streams.sh
go build -o bin/server ./cmd/server && ./bin/server
```

Open [http://localhost:8080](http://localhost:8080) in your browser.

### Build & Test

```bash
make build    # Build Go server → ./bin/server
make test     # Run unit tests
make clean    # Remove build artifacts
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8080` | HTTP server port |
| `MEDIAMTX_API` | `http://localhost:9997` | MediaMTX API URL |
| `MEDIAMTX_RTSP` | `rtsp://localhost:8554` | MediaMTX RTSP URL |
| `MEDIAMTX_HLS` | `:8888` | MediaMTX HLS proxy address |
| `MEDIAMTX_WEBRTC` | `:8889` | MediaMTX WebRTC proxy address |
| `RTMP_OUTPUT` | `rtmp://localhost:1935/live-output` | Default RTMP output |
| `BRIDGE_ADDR` | `:8555` | Bridge proxy listen address |
| `CAMERAS` | `cam2,cam3` | Comma-separated camera names |
| `OVERLAY_DIR` | `/tmp/media-mtx-overlay` | Overlay PNG directory |
| `AUDIO_DEVICE` | _(empty)_ | macOS audio device index |

## API

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/streams` | List cameras with ready status |
| `GET` | `/api/status` | Switcher state (live, active stream, RTMP dest) |
| `POST` | `/api/switch` | Switch camera (`{"stream": "cam3"}`) |
| `POST` | `/api/live/start` | Start streaming (`{"stream", "youtube_key", "audio"}`) |
| `POST` | `/api/live/stop` | Stop streaming |
| `GET/POST` | `/api/config` | Read/write persistent UI config |
| | | |
| `POST` | `/api/overlay/start` | Start timing overlay (`{"url", "format", "scale", "title"}`) |
| `POST` | `/api/overlay/stop` | Stop overlay |
| `POST` | `/api/overlay/update` | Hot-update format, scale, rows, title without restart |
| `GET` | `/api/overlay/status` | Overlay active status + competitor count |
| `POST` | `/api/overlay/flag` | Set flag status (`{"status": "red"}`) or clear |
| | | |
| `POST` | `/api/logo/upload` | Upload logo PNG (`multipart: file, position`) |
| `DELETE` | `/api/logo/{position}` | Remove logo (`top-right` or `bottom-right`) |
| `GET` | `/api/logo/status` | Logo state (has_logo, enabled, opacity, offset, scale) |
| `POST` | `/api/logo/settings` | Update opacity, offset, scale, enabled per logo |
| `GET` | `/api/logo/preview/{position}` | Serve current logo image |
| | | |
| `POST` | `/api/ads/upload` | Upload ad video (auto-transcoded) |
| `GET` | `/api/ads` | List ads with status and duration |
| `DELETE` | `/api/ads/{id}` | Delete an ad |
| `POST` | `/api/ads/play` | Play selected ads |
| `POST` | `/api/ads/stop` | Stop ad break |
| `GET` | `/api/ads/playback` | Current ad playback state |
| | | |
| `GET` | `/api/commentary/status` | Commentary config (enabled, volumes, slots) |
| `POST` | `/api/commentary/update` | Set commentary enabled + camera volume |
| `POST` | `/api/commentary/slot` | Update commentator slot (active, volume) |
| `POST` | `/api/commentary/kick` | Kick a commentator from their slot |
| | | |
| `POST` | `/api/fleet/heartbeat` | Pi camera heartbeat (temp, uptime, Starlink) |
| `GET` | `/api/fleet/status` | Fleet dashboard data |
| | | |
| `POST` | `/api/debug/restart` | Restart MediaMTX or stream server |
| `GET` | `/api/debug/logs` | Fetch recent service logs |
| `GET` | `/api/audio/devices` | List macOS audio devices |
| `GET` | `/api/version` | Build version info |
| | | |
| `GET` | `/viewer` | Full-screen multi-camera viewer page |
| `GET` | `/fleet` | Pi camera fleet dashboard |
| `GET` | `/debug` | Debug tools page |

## AWS Deployment

### Infrastructure

Terraform provisions the full stack in `us-west-2`:

- **VPC** — 10.0.0.0/16 with 2 public subnets
- **EC2** — c6i.xlarge, Ubuntu 24.04, Elastic IP, cloud-init provisioning
- **ALB** — HTTPS termination (ACM cert), routes :443 → :8080
- **NLB** — L4 passthrough for RTMP (:1935) and WebRTC ICE (:8189 TCP+UDP)
- **Security Groups** — SSH, HTTP from ALB, RTMP/WebRTC from internet

```
Internet
  │
Cloudflare DNS (proxy OFF)
  ├── stream.racetrackstreaming.com → ALB (HTTPS :443)
  └── rtmp.racetrackstreaming.com   → NLB (RTMP :1935, WebRTC :8189)
                    │
          ┌─────────▼──────────┐
          │  EC2 (c6i.xlarge)  │
          │  Ubuntu 24.04      │
          │  ├── MediaMTX      │
          │  ├── Go Server     │
          │  └── GStreamer     │
          └────────────────────┘
```

### Deploy

```bash
# One-time infrastructure setup
cd deploy/terraform
terraform init && terraform apply

# Deploy code updates
make deploy   # Cross-compile → SCP → restart systemd services

# SSH access
ssh -i ~/.ssh/racetrack-streaming.pem ubuntu@<ELASTIC_IP>
```

## Raspberry Pi Camera Setup

Each Pi runs `rpicam-stream.sh` as a systemd service, pushing H.264+Opus over RTMP (or SRT for lower latency):

```bash
# On the Pi
sudo cp rpi/rpicam-stream.service /etc/systemd/system/
sudo systemctl enable --now rpicam-stream

# Config: /etc/rpicam-stream.conf
MEDIAMTX_HOST=rtmp.racetrackstreaming.com
STREAM_NAME=cam2
WIDTH=1280
HEIGHT=720
FPS=30
BITRATE=3000
```

Networking options: WiFi, Tailscale VPN, or 5G cellular modem (scripts in `rpi/cellular/`).
