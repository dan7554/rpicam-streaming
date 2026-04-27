package bridge

import (
	"fmt"
	"log"
	"sync"

	"github.com/bluenviron/gortsplib/v5"
	"github.com/bluenviron/gortsplib/v5/pkg/base"
	"github.com/bluenviron/gortsplib/v5/pkg/description"
	"github.com/bluenviron/gortsplib/v5/pkg/format"
	"github.com/pion/rtp"
)

// Bridge is an RTSP switching proxy. It connects to multiple camera RTSP
// streams simultaneously and serves a single output stream. Switching cameras
// changes which source's packets are forwarded — zero-gap.
type Bridge struct {
	mu             sync.RWMutex
	addr           string
	rtspBase       string
	active         string
	needsKeyframe  bool                // after switch, drop video until IDR
	server         *gortsplib.Server
	stream         *gortsplib.ServerStream
	clients        []*gortsplib.Client
	serverMedias   []*description.Media
}

// New creates a bridge that listens on addr (e.g. ":8555") and reads cameras
// from rtspBase (e.g. "rtsp://localhost:8554").
func New(addr, rtspBase string) *Bridge {
	log.Printf("[bridge] New: addr=%s rtspBase=%s", addr, rtspBase)
	return &Bridge{
		addr:     addr,
		rtspBase: rtspBase,
	}
}

// Start connects to all cameras and starts the RTSP server.
func (b *Bridge) Start(cameras []string, active string) error {
	log.Printf("[bridge] Start: cameras=%v active=%s", cameras, active)
	b.mu.Lock()
	b.active = active
	b.mu.Unlock()

	b.server = &gortsplib.Server{
		Handler:        b,
		RTSPAddress:    b.addr,
		WriteQueueSize: 1024,
	}
	if err := b.server.Start(); err != nil {
		log.Printf("[bridge] RTSP server start FAILED: %v", err)
		return fmt.Errorf("bridge server: %w", err)
	}
	log.Printf("[bridge] RTSP server listening on %s", b.addr)

	for i, cam := range cameras {
		log.Printf("[bridge] connecting camera %d/%d: %s (first=%v)", i+1, len(cameras), cam, i == 0)
		if err := b.connectCamera(cam, i == 0); err != nil {
			log.Printf("[bridge] camera %s connect FAILED: %v", cam, err)
			b.Stop()
			return fmt.Errorf("connect %s: %w", cam, err)
		}
	}

	log.Printf("[bridge] started on rtsp://localhost%s/stream (%d cameras, active: %s)",
		b.addr, len(cameras), active)

	return nil
}

func (b *Bridge) connectCamera(name string, first bool) error {
	rawURL := b.rtspBase + "/" + name
	log.Printf("[bridge] connectCamera: %s (URL=%s first=%v)", name, rawURL, first)
	u, err := base.ParseURL(rawURL)
	if err != nil {
		return err
	}

	c := &gortsplib.Client{
		Scheme: u.Scheme,
		Host:   u.Host,
	}
	if err := c.Start(); err != nil {
		log.Printf("[bridge] connectCamera %s: client start FAILED: %v", name, err)
		return err
	}

	desc, _, err := c.Describe(u)
	if err != nil {
		log.Printf("[bridge] connectCamera %s: DESCRIBE FAILED: %v", name, err)
		c.Close()
		return err
	}

	log.Printf("[bridge] connectCamera %s: DESCRIBE returned %d medias", name, len(desc.Medias))
	for i, m := range desc.Medias {
		fmtNames := make([]string, len(m.Formats))
		for j, f := range m.Formats {
			fmtNames[j] = fmt.Sprintf("%T", f)
		}
		log.Printf("[bridge] connectCamera %s:   media[%d] type=%s formats=%v", name, i, m.Type, fmtNames)
	}

	if err := c.SetupAll(desc.BaseURL, desc.Medias); err != nil {
		log.Printf("[bridge] connectCamera %s: SETUP FAILED: %v", name, err)
		c.Close()
		return err
	}

	if first {
		log.Printf("[bridge] connectCamera %s: first camera, creating server stream (VIDEO ONLY)", name)
		// Build a video-only server stream description. Audio is provided by
		// FFmpeg's anullsrc, so the bridge must never carry audio — otherwise
		// FFmpeg's RTSP demuxer stalls waiting for audio packets when the
		// active camera has no audio track.
		videoOnlyMedias := make([]*description.Media, 0, 1)
		for _, m := range desc.Medias {
			if m.Type == description.MediaTypeVideo {
				videoOnlyMedias = append(videoOnlyMedias, m)
			}
		}
		videoDesc := &description.Session{Medias: videoOnlyMedias}
		b.stream = &gortsplib.ServerStream{
			Server: b.server,
			Desc:   videoDesc,
		}
		if err := b.stream.Initialize(); err != nil {
			c.Close()
			return err
		}
		b.serverMedias = videoOnlyMedias
		log.Printf("[bridge] connectCamera %s: server stream has %d medias (video only)", name, len(videoOnlyMedias))
	}

	// Map client video media → server video media. Audio is ignored.
	mediaMap := make(map[*description.Media]*description.Media)
	for _, cm := range desc.Medias {
		if cm.Type != description.MediaTypeVideo {
			continue // skip audio — handled by anullsrc in FFmpeg
		}
		for _, sm := range b.serverMedias {
			if cm.Type == sm.Type {
				mediaMap[cm] = sm
				log.Printf("[bridge] connectCamera %s: mapped video media (client → server)", name)
				break
			}
		}
	}

	camName := name
	c.OnPacketRTPAny(func(medi *description.Media, _ format.Format, pkt *rtp.Packet) {
		// Only forward video — audio is handled by anullsrc in FFmpeg.
		if medi.Type != description.MediaTypeVideo {
			return
		}
		b.mu.RLock()
		isActive := b.active == camName
		needsKF := b.needsKeyframe
		b.mu.RUnlock()
		if !isActive {
			return
		}
		// After a switch, drop video until we see a keyframe (IDR).
		if needsKF {
			if !isH264Keyframe(pkt) {
				return
			}
			b.mu.Lock()
			b.needsKeyframe = false
			b.mu.Unlock()
			log.Printf("[bridge] keyframe received from %s, resuming forwarding", camName)
		}
		if sm, ok := mediaMap[medi]; ok {
			if err := b.stream.WritePacketRTP(sm, pkt); err != nil {
				log.Printf("bridge write error: %v", err)
			}
		}
	})

	_, err = c.Play(nil)
	if err != nil {
		log.Printf("[bridge] connectCamera %s: PLAY FAILED: %v", name, err)
		c.Close()
		return err
	}

	log.Printf("[bridge] connectCamera %s: PLAYING (mapped %d medias, video-only)", name, len(mediaMap))
	b.clients = append(b.clients, c)
	return nil
}

// isH264Keyframe checks if an RTP packet contains the start of an H264 IDR
// (keyframe). Handles single NAL, STAP-A, and FU-A packetization.
func isH264Keyframe(pkt *rtp.Packet) bool {
	if len(pkt.Payload) == 0 {
		return false
	}
	nalType := pkt.Payload[0] & 0x1F
	switch {
	case nalType >= 1 && nalType <= 23:
		// Single NAL unit: type 5 = IDR, type 7 = SPS
		return nalType == 5 || nalType == 7
	case nalType == 24:
		// STAP-A: aggregated NALs, check first contained NAL
		if len(pkt.Payload) > 3 {
			innerType := pkt.Payload[3] & 0x1F
			return innerType == 5 || innerType == 7
		}
	case nalType == 28:
		// FU-A: fragmented NAL, check start bit + NAL type
		if len(pkt.Payload) > 1 {
			startBit := pkt.Payload[1] & 0x80
			fuType := pkt.Payload[1] & 0x1F
			return startBit != 0 && fuType == 5
		}
	}
	return false
}

// Switch changes the active camera atomically (zero-gap).
func (b *Bridge) Switch(camera string) {
	b.mu.Lock()
	old := b.active
	b.active = camera
	b.needsKeyframe = true // wait for IDR from new camera
	b.mu.Unlock()

	log.Printf("[bridge] Switch: %s → %s (waitingForKeyframe=true)", old, camera)
	log.Printf("[bridge] switched to %s", camera)
}

// ProxyURL returns the RTSP URL of the bridge output.
func (b *Bridge) ProxyURL() string {
	return "rtsp://localhost" + b.addr + "/stream"
}

// Stop shuts down the bridge server and all camera connections.
func (b *Bridge) Stop() {
	log.Printf("[bridge] Stop: shutting down (%d clients)", len(b.clients))
	for i, c := range b.clients {
		log.Printf("[bridge] Stop: closing client %d", i)
		c.Close()
	}
	b.clients = nil
	if b.stream != nil {
		b.stream.Close()
		b.stream = nil
	}
	if b.server != nil {
		b.server.Close()
		b.server = nil
	}
	log.Printf("[bridge] stopped")
}

// RTSP server handler implementations

func (b *Bridge) OnConnOpen(ctx *gortsplib.ServerHandlerOnConnOpenCtx)     {
	log.Printf("[bridge] RTSP client connected")
}
func (b *Bridge) OnConnClose(ctx *gortsplib.ServerHandlerOnConnCloseCtx)   {
	log.Printf("[bridge] RTSP client disconnected")
}
func (b *Bridge) OnSessionOpen(ctx *gortsplib.ServerHandlerOnSessionOpenCtx)   {
	log.Printf("[bridge] RTSP session opened")
}
func (b *Bridge) OnSessionClose(ctx *gortsplib.ServerHandlerOnSessionCloseCtx) {
	log.Printf("[bridge] RTSP session closed")
}

func (b *Bridge) OnDescribe(ctx *gortsplib.ServerHandlerOnDescribeCtx) (*base.Response, *gortsplib.ServerStream, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	log.Printf("[bridge] RTSP DESCRIBE request (stream=%v)", b.stream != nil)
	if b.stream == nil {
		return &base.Response{StatusCode: base.StatusNotFound}, nil, nil
	}
	return &base.Response{StatusCode: base.StatusOK}, b.stream, nil
}

func (b *Bridge) OnSetup(ctx *gortsplib.ServerHandlerOnSetupCtx) (*base.Response, *gortsplib.ServerStream, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	log.Printf("[bridge] RTSP SETUP request (stream=%v)", b.stream != nil)
	if b.stream == nil {
		return &base.Response{StatusCode: base.StatusNotFound}, nil, nil
	}
	return &base.Response{StatusCode: base.StatusOK}, b.stream, nil
}

func (b *Bridge) OnPlay(ctx *gortsplib.ServerHandlerOnPlayCtx) (*base.Response, error) {
	log.Printf("[bridge] RTSP PLAY request")
	return &base.Response{StatusCode: base.StatusOK}, nil
}
