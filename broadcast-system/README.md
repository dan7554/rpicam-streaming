# Racetrack Broadcasting System

A professional multi-camera streaming system designed for racetrack broadcasting with real-time camera switching, voice commentary, and direct YouTube streaming integration.

## Features

### 🎥 Multi-Camera Management
- Support for unlimited camera sources (RTSP, WebRTC, IP cameras)
- Real-time camera switching with smooth transitions
- Picture-in-picture and split-screen layouts
- Custom scene presets for different race scenarios

### 🎙️ Voice Commentary System
- WebRTC-based real-time audio input
- Multiple commentator support
- Audio mixing with background music
- Push-to-talk and always-on modes

### 📡 Live Streaming
- Direct RTMP streaming to YouTube Live
- Integration with existing MediaMTX infrastructure
- Adaptive bitrate streaming
- Stream health monitoring

### 🎛️ Admin Control Dashboard
- Intuitive web-based control interface
- Real-time preview of all camera sources
- Scene composition with drag-and-drop
- Stream status and analytics

## Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Camera 1      │    │                  │    │                 │
│   (Pi Camera)   ├────┤                  │    │   YouTube Live  │
└─────────────────┘    │                  │    │                 │
┌─────────────────┐    │   Broadcast      │    │                 │
│   Camera 2      │    │   Control        ├────┤   RTMP Stream   │
│   (IP Camera)   ├────┤   System         │    │                 │
└─────────────────┘    │                  │    └─────────────────┘
┌─────────────────┐    │                  │    
│   Camera N      │    │                  │    ┌─────────────────┐
│   (RTSP)        ├────┤                  │    │   MediaMTX      │
└─────────────────┘    └──────────────────┘    │   Server        │
┌─────────────────┐                            │                 │
│   Voice         │                            └─────────────────┘
│   Commentary    ├────────────────────────────┤
└─────────────────┘                            
```

## Quick Start

### Prerequisites
- Node.js 18+
- FFmpeg
- Docker (optional)
- MediaMTX server (existing)

### Installation

1. Install dependencies:
```bash
npm run install:all
```

2. Configure your camera sources in `config/cameras.json`

3. Set up YouTube streaming credentials in `config/streaming.json`

4. Start the system:
```bash
npm run dev
```

5. Access the admin dashboard at `http://localhost:3000`

### Integration with Existing MediaMTX

This system is designed to work seamlessly with your existing MediaMTX setup:

- Camera sources connect to MediaMTX paths
- Admin system pulls streams via WebRTC/HLS
- Composed output streams back to MediaMTX
- MediaMTX handles RTMP distribution to YouTube

## Configuration

### Camera Sources
Add your camera sources to `config/cameras.json`:

```json
{
  "cameras": [
    {
      "id": "pit-lane",
      "name": "Pit Lane",
      "type": "rtsp",
      "url": "rtsp://your-mediamtx-server:8554/rpicam",
      "position": { "x": 0, "y": 0, "width": 1920, "height": 1080 }
    },
    {
      "id": "turn-1",
      "name": "Turn 1",
      "type": "webrtc",
      "url": "http://your-mediamtx-server:8889/turn1/whep",
      "position": { "x": 1920, "y": 0, "width": 1920, "height": 1080 }
    }
  ]
}
```

### Scene Presets
Define scene layouts in `config/scenes.json`:

```json
{
  "scenes": [
    {
      "id": "race-start",
      "name": "Race Start",
      "layout": "full-screen",
      "primary_camera": "pit-lane",
      "overlays": ["race-timer", "leaderboard"]
    },
    {
      "id": "multi-view",
      "name": "Multi Camera",
      "layout": "quad-split",
      "cameras": ["pit-lane", "turn-1", "turn-2", "finish-line"]
    }
  ]
}
```

## API Endpoints

### Camera Management
- `GET /api/cameras` - List all cameras
- `POST /api/cameras` - Add new camera
- `PUT /api/cameras/:id` - Update camera settings
- `DELETE /api/cameras/:id` - Remove camera

### Scene Control
- `GET /api/scenes` - List all scenes
- `POST /api/scenes/switch/:id` - Switch to scene
- `PUT /api/scenes/:id` - Update scene layout

### Streaming Control
- `POST /api/stream/start` - Start YouTube stream
- `POST /api/stream/stop` - Stop stream
- `GET /api/stream/status` - Get stream health

## WebSocket Events

Real-time communication for live control:

```javascript
// Camera switching
socket.emit('switch-camera', { cameraId: 'pit-lane' });

// Scene transition
socket.emit('switch-scene', { sceneId: 'race-start', transition: 'fade' });

// Commentary control
socket.emit('commentary-start', { commentatorId: 'main' });
```

## Docker Deployment

Build and run with Docker:

```bash
npm run docker:build
npm run docker:run
```

Or use with your existing docker-compose setup:

```yaml
services:
  broadcast-system:
    build: ./broadcast-system
    ports:
      - "3000:3000"
      - "8080:8080"
    environment:
      - MEDIAMTX_URL=http://mediamtx:8888
      - YOUTUBE_RTMP_URL=rtmp://a.rtmp.youtube.com/live2/
    depends_on:
      - mediamtx
```

## Development

### Project Structure
```
broadcast-system/
├── server/                 # Node.js backend
│   ├── index.js           # Main server
│   ├── routes/            # API routes
│   ├── services/          # Core services
│   └── websocket/         # WebSocket handlers
├── client/                # React frontend
│   ├── src/
│   │   ├── components/    # UI components
│   │   ├── pages/         # Dashboard pages
│   │   └── services/      # API clients
├── config/                # Configuration files
├── docker/                # Docker configurations
└── docs/                  # Documentation
```

### Adding New Features

1. **New Camera Types**: Extend `services/CameraManager.js`
2. **Custom Layouts**: Add layouts in `services/SceneComposer.js`
3. **Stream Outputs**: Modify `services/StreamManager.js`

## Production Deployment

### AWS ECS Integration
Works with your existing MediaMTX ECS deployment:

```bash
# Build for production
make broadcast-deploy

# Monitor deployment
make broadcast-logs
```

### Performance Optimization
- Hardware-accelerated encoding (NVENC/VAAPI)
- CDN integration for global distribution
- Auto-scaling based on viewership
- Load balancing for multiple streams

## Troubleshooting

### Common Issues

**Camera Connection Failed**
```bash
# Check MediaMTX connectivity
curl http://your-mediamtx-server:8888/v3/paths/list

# Test RTSP stream
ffplay rtsp://your-mediamtx-server:8554/rpicam
```

**YouTube Streaming Issues**
```bash
# Verify RTMP endpoint
ffmpeg -re -i test.mp4 -c copy -f flv rtmp://a.rtmp.youtube.com/live2/YOUR_KEY
```

**Audio Sync Problems**
- Check audio buffer settings in config
- Ensure consistent frame rates across cameras
- Monitor system resource usage

## License

MIT License - see LICENSE file for details.

## Support

For racetrack broadcasting specific setup, integration help, or custom features, please open an issue or contact the development team.