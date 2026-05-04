package bridge

import (
	"fmt"
	"log"
	"sort"
	"sync"
	"time"

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
	active           string
	needsKeyframe    bool                // after switch, drop all until IDR
	switchTime       time.Time           // when last switch was requested
	droppedVideoPkts int                 // video packets dropped waiting for keyframe
	server           *gortsplib.Server
	stream         *gortsplib.ServerStream
	clients        []*gortsplib.Client
	cameras        []string             // camera names, parallel to clients
	serverMedias   []*description.Media
	stopCh         chan struct{}         // closed on Stop to halt reconnect goroutines

	// RTP timestamp/seq rewriting to ensure continuity across camera switches.
	// Without this, switching cameras causes timestamp discontinuities that
	// crash GStreamer's flvmux → rtmp2sink.
	lastVideoTS  uint32 // last video RTP timestamp we wrote
	lastVideoSeq uint16 // last video RTP sequence number we wrote
	videoTSOffset    int64  // added to incoming video timestamps
	videoSeqOffset   int32  // added to incoming video sequence numbers
	pendingVideoRebase bool // true = next video keyframe needs offset recalculation

	// Audio uses monotonic timestamp regeneration instead of offset-based
	// rewriting. The Pi sends audio in burst pairs which cause GStreamer's
	// jitter buffer to randomly produce artifacts on startup.
	// We regenerate perfectly-spaced timestamps so downstream sees clean timing.
	// Opus at 48kHz with 20ms frames = 960 samples per frame.
	nextAudioTS  uint32 // next audio RTP timestamp to assign
	nextAudioSeq uint16 // next audio RTP sequence number to assign
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
	b.stopCh = make(chan struct{})
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

	// Probe all cameras to find media counts, then connect the one with the
	// most medias first so the server stream template includes audio if any
	// camera has it. Without this, a video-only camera connected first would
	// create a video-only template, silently dropping audio from other cameras.
	type camProbe struct {
		name       string
		mediaCount int
	}
	probes := make([]camProbe, len(cameras))
	for i, cam := range cameras {
		rawURL := b.rtspBase + "/" + cam
		u, _ := base.ParseURL(rawURL)
		c := &gortsplib.Client{Scheme: u.Scheme, Host: u.Host}
		if err := c.Start(); err != nil {
			probes[i] = camProbe{cam, 0}
			continue
		}
		desc, _, err := c.Describe(u)
		c.Close()
		if err != nil {
			probes[i] = camProbe{cam, 0}
			continue
		}
		probes[i] = camProbe{cam, len(desc.Medias)}
		log.Printf("[bridge] probe %s: %d medias", cam, len(desc.Medias))
	}
	sort.SliceStable(probes, func(i, j int) bool {
		return probes[i].mediaCount > probes[j].mediaCount
	})
	sorted := make([]string, len(probes))
	for i, p := range probes {
		sorted[i] = p.name
	}
	log.Printf("[bridge] connection order (most medias first): %v", sorted)

	for i, cam := range sorted {
		log.Printf("[bridge] connecting camera %d/%d: %s (first=%v)", i+1, len(sorted), cam, i == 0)
		if err := b.connectCamera(cam, i == 0); err != nil {
			log.Printf("[bridge] camera %s connect FAILED: %v", cam, err)
			b.Stop()
			return fmt.Errorf("connect %s: %w", cam, err)
		}
	}

	// Start reconnect monitors for each camera
	b.cameras = sorted
	for i, cam := range sorted {
		go b.monitorCamera(i, cam)
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
		log.Printf("[bridge] connectCamera %s: first camera, creating server stream", name)
		b.stream = &gortsplib.ServerStream{
			Server: b.server,
			Desc:   desc,
		}
		if err := b.stream.Initialize(); err != nil {
			c.Close()
			return err
		}
		b.serverMedias = desc.Medias
		log.Printf("[bridge] connectCamera %s: server stream has %d medias", name, len(desc.Medias))
	}

	// Map client medias → server medias by type (video → video, audio → audio).
	mediaMap := make(map[*description.Media]*description.Media)
	for _, cm := range desc.Medias {
		for _, sm := range b.serverMedias {
			if cm.Type == sm.Type {
				mediaMap[cm] = sm
				log.Printf("[bridge] connectCamera %s: mapped %s media (client → server)", name, cm.Type)
				break
			}
		}
	}

	camName := name
	c.OnPacketRTPAny(func(medi *description.Media, _ format.Format, pkt *rtp.Packet) {
		b.mu.RLock()
		isActive := b.active == camName
		needsKF := b.needsKeyframe
		b.mu.RUnlock()
		if !isActive {
			return
		}
		// After a switch, drop ALL packets until we see a keyframe (IDR).
		// This ensures clean A/V sync — no audio from new camera before video.
		if needsKF {
			if medi.Type == description.MediaTypeVideo {
				if !isH264Keyframe(pkt) {
					b.mu.Lock()
					b.droppedVideoPkts++
					b.mu.Unlock()
					return
				}
				b.mu.Lock()
				elapsed := time.Since(b.switchTime)
				dropped := b.droppedVideoPkts
				b.needsKeyframe = false
				b.droppedVideoPkts = 0

				// Rebase video: compute offsets so new camera's timestamps continue
				// from where the old camera left off (video clock = 90kHz).
				if b.pendingVideoRebase {
					b.videoTSOffset = int64(b.lastVideoTS) - int64(pkt.Timestamp) + 3000 // +1 frame gap at 90kHz/30fps
					b.videoSeqOffset = int32(b.lastVideoSeq) - int32(pkt.SequenceNumber) + 1
					b.pendingVideoRebase = false
					log.Printf("[bridge] rebase video: tsOffset=%d seqOffset=%d",
						b.videoTSOffset, b.videoSeqOffset)
				}
				b.mu.Unlock()
				log.Printf("[bridge] keyframe received from %s in %dms (dropped %d video pkts)",
					camName, elapsed.Milliseconds(), dropped)
			} else {
				// Drop audio too until keyframe arrives
				return
			}
		}
		if sm, ok := mediaMap[medi]; ok {
			// Apply timestamp/sequence rewriting for continuity across switches.
			b.mu.Lock()
			if medi.Type == description.MediaTypeVideo {
				pkt.Timestamp = uint32(int64(pkt.Timestamp) + b.videoTSOffset)
				pkt.SequenceNumber = uint16(int32(pkt.SequenceNumber) + b.videoSeqOffset)
				b.lastVideoTS = pkt.Timestamp
				b.lastVideoSeq = pkt.SequenceNumber
			} else {
				// Monotonic audio timestamp regeneration: assign perfectly-
				// spaced timestamps (960 samples per Opus frame at 48kHz/20ms)
				// instead of forwarding the Pi's jittery burst timestamps.
				pkt.Timestamp = b.nextAudioTS
				pkt.SequenceNumber = b.nextAudioSeq
				b.nextAudioTS += 960 // 960 samples per Opus frame (20ms at 48kHz)
				b.nextAudioSeq++
			}
			b.mu.Unlock()
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

	log.Printf("[bridge] connectCamera %s: PLAYING (mapped %d medias)", name, len(mediaMap))
	b.clients = append(b.clients, c)
	return nil
}

// monitorCamera watches a camera's RTSP client for disconnection and
// reconnects with exponential backoff.
func (b *Bridge) monitorCamera(idx int, name string) {
	for {
		b.mu.RLock()
		c := b.clients[idx]
		b.mu.RUnlock()

		err := c.Wait()

		// Check if bridge is shutting down
		select {
		case <-b.stopCh:
			return
		default:
		}

		log.Printf("[bridge] camera %s disconnected: %v", name, err)

		// Reconnect with exponential backoff
		backoff := 2 * time.Second
		maxBackoff := 30 * time.Second
		for {
			select {
			case <-b.stopCh:
				return
			default:
			}

			log.Printf("[bridge] reconnecting camera %s in %v...", name, backoff)

			select {
			case <-time.After(backoff):
			case <-b.stopCh:
				return
			}

			if err := b.reconnectCamera(idx, name); err != nil {
				log.Printf("[bridge] camera %s reconnect FAILED: %v", name, err)
				backoff *= 2
				if backoff > maxBackoff {
					backoff = maxBackoff
				}
				continue
			}

			log.Printf("[bridge] camera %s reconnected successfully", name)
			break
		}
	}
}

// reconnectCamera replaces the client at the given index with a fresh connection.
func (b *Bridge) reconnectCamera(idx int, name string) error {
	rawURL := b.rtspBase + "/" + name
	u, err := base.ParseURL(rawURL)
	if err != nil {
		return err
	}

	c := &gortsplib.Client{
		Scheme: u.Scheme,
		Host:   u.Host,
	}
	if err := c.Start(); err != nil {
		return fmt.Errorf("client start: %w", err)
	}

	desc, _, err := c.Describe(u)
	if err != nil {
		c.Close()
		return fmt.Errorf("DESCRIBE: %w", err)
	}

	if err := c.SetupAll(desc.BaseURL, desc.Medias); err != nil {
		c.Close()
		return fmt.Errorf("SETUP: %w", err)
	}

	// Map client medias → server medias by type
	b.mu.RLock()
	serverMedias := b.serverMedias
	b.mu.RUnlock()

	mediaMap := make(map[*description.Media]*description.Media)
	for _, cm := range desc.Medias {
		for _, sm := range serverMedias {
			if cm.Type == sm.Type {
				mediaMap[cm] = sm
				break
			}
		}
	}

	camName := name
	c.OnPacketRTPAny(func(medi *description.Media, _ format.Format, pkt *rtp.Packet) {
		b.mu.RLock()
		isActive := b.active == camName
		needsKF := b.needsKeyframe
		b.mu.RUnlock()
		if !isActive {
			return
		}
		if needsKF {
			if medi.Type == description.MediaTypeVideo {
				if !isH264Keyframe(pkt) {
					b.mu.Lock()
					b.droppedVideoPkts++
					b.mu.Unlock()
					return
				}
				b.mu.Lock()
				elapsed := time.Since(b.switchTime)
				dropped := b.droppedVideoPkts
				b.needsKeyframe = false
				b.droppedVideoPkts = 0
				if b.pendingVideoRebase {
					b.videoTSOffset = int64(b.lastVideoTS) - int64(pkt.Timestamp) + 3000
					b.videoSeqOffset = int32(b.lastVideoSeq) - int32(pkt.SequenceNumber) + 1
					b.pendingVideoRebase = false
				}
				b.mu.Unlock()
				log.Printf("[bridge] keyframe received from %s in %dms (dropped %d video pkts)",
					camName, elapsed.Milliseconds(), dropped)
			} else {
				return
			}
		}
		if sm, ok := mediaMap[medi]; ok {
			b.mu.Lock()
			if medi.Type == description.MediaTypeVideo {
				pkt.Timestamp = uint32(int64(pkt.Timestamp) + b.videoTSOffset)
				pkt.SequenceNumber = uint16(int32(pkt.SequenceNumber) + b.videoSeqOffset)
				b.lastVideoTS = pkt.Timestamp
				b.lastVideoSeq = pkt.SequenceNumber
			} else {
				pkt.Timestamp = b.nextAudioTS
				pkt.SequenceNumber = b.nextAudioSeq
				b.nextAudioTS += 960
				b.nextAudioSeq++
			}
			b.mu.Unlock()
			if err := b.stream.WritePacketRTP(sm, pkt); err != nil {
				log.Printf("bridge write error: %v", err)
			}
		}
	})

	_, err = c.Play(nil)
	if err != nil {
		c.Close()
		return fmt.Errorf("PLAY: %w", err)
	}

	// Force a keyframe wait if this is the active camera reconnecting
	b.mu.Lock()
	b.clients[idx] = c
	if b.active == name {
		b.needsKeyframe = true
		b.pendingVideoRebase = true
		b.switchTime = time.Now()
		b.droppedVideoPkts = 0
		log.Printf("[bridge] active camera %s reconnected, waiting for keyframe", name)
	}
	b.mu.Unlock()

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

// Switch changes the active camera atomically.
// Waits for next live keyframe from new camera (max ~267ms with GOP=8 at 30fps).
// Both audio and video are held until keyframe arrives for clean A/V sync.
func (b *Bridge) Switch(camera string) {
	b.mu.Lock()
	old := b.active
	b.active = camera
	b.needsKeyframe = true
	b.pendingVideoRebase = true
	b.switchTime = time.Now()
	b.droppedVideoPkts = 0
	b.mu.Unlock()

	log.Printf("[bridge] Switch: %s → %s (waiting for live keyframe)", old, camera)
}

// ProxyURL returns the RTSP URL of the bridge output.
func (b *Bridge) ProxyURL() string {
	return "rtsp://localhost" + b.addr + "/stream"
}

// Stop shuts down the bridge server and all camera connections.
func (b *Bridge) Stop() {
	log.Printf("[bridge] Stop: shutting down (%d clients)", len(b.clients))
	// Signal monitor goroutines to stop
	if b.stopCh != nil {
		close(b.stopCh)
	}
	for i, c := range b.clients {
		log.Printf("[bridge] Stop: closing client %d", i)
		c.Close()
	}
	b.clients = nil
	b.cameras = nil
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
	log.Printf("[bridge] RTSP PLAY request — full state reset")
	// Full reset: any packets forwarded before the client connected left
	// stale lastTS/lastSeq values that don't correspond to anything the
	// client actually received. Reset everything so the first keyframe
	// after PLAY produces clean, properly-based timestamps.
	b.mu.Lock()
	b.needsKeyframe = true
	b.pendingVideoRebase = false // no rebase needed — starting fresh
	b.switchTime = time.Now()
	b.droppedVideoPkts = 0
	b.lastVideoTS = 0
	b.lastVideoSeq = 0
	b.videoTSOffset = 0
	b.videoSeqOffset = 0
	b.nextAudioTS = 0
	b.nextAudioSeq = 0
	b.mu.Unlock()
	return &base.Response{StatusCode: base.StatusOK}, nil
}
