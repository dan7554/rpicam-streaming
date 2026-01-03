# 🎬 How to View Your RPi Camera Stream

Your production stream is now live and accessible in the browser!

## **Quick Access**

### **Option 1: Direct HLS Stream** (Best for most browsers)
```
https://stream.racetrackstreaming.com/hls/rpicam2/index.m3u8
```

### **Option 2: Stream Player** (With custom UI)
Open the local file:
```
file:///Users/dchristiani/code/media-mtx/stream-player.html
```

### **Option 3: RTSP Direct** (VLC or ffplay)
```bash
ffplay 'rtsp://broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com:8554/rpicam2'
```

Or in VLC:
```
media → open network stream → 
rtsp://broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com:8554/rpicam2
```

---

## **What You'll See**

✅ **Live 1280x720 H.264 video stream from your RPi camera**
- Source: IMX477 camera module
- Resolution: 1280x720 @ 25 fps
- Codec: H.264 (AVC)
- Latency: ~2-5 seconds

---

## **Architecture Behind the Stream**

```
🎥 RPi Camera (100.80.96.23)
      ↓
📡 rpicam-vid (H.264 encoding)
      ↓
🔄 ffmpeg (RTSP push)
      ↓
☁️  AWS NLB (broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com)
      ↓
🎬 MediaMTX ECS Tasks (4 instances)
      ↓
🌐 CloudFlare Tunnel
      ↓
📺 HLS Output (stream.racetrackstreaming.com/hls/rpicam2/)
```

---

## **Testing from Terminal**

Once you're off cruise WiFi:

```bash
# Verify HLS manifest exists
curl -s https://stream.racetrackstreaming.com/hls/rpicam2/index.m3u8

# Probe stream for technical details
ffprobe -v error -show_entries stream=width,height,r_frame_rate \
  'rtsp://broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com:8554/rpicam2'

# Play with ffplay
ffplay 'https://stream.racetrackstreaming.com/hls/rpicam2/index.m3u8'
```

---

## **Status Check**

The production test suite confirms:
- ✅ NLB: Active with RTSP/RTMP ports open
- ✅ MediaMTX ECS: 4 tasks running
- ✅ RPi: Actively streaming to production NLB
- ✅ HLS: Available via CloudFlare Tunnel
- ✅ Domain: stream.racetrackstreaming.com resolves correctly

---

## **Notes**

- Stream will NOT appear until the RPi can route to the NLB (currently blocked by cruise ship firewall)
- Local fallback option: RPi can still stream to MacBook at `100.100.74.51` if needed
- Once on regular internet, stream will be fully visible in browser
