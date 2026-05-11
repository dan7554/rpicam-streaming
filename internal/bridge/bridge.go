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

	// Audio uses offset-based rewriting like video to maintain
	// timestamp continuity across source switches.
	lastAudioTS      uint32
	lastAudioSeq     uint16
	audioTSOffset    int64
	audioSeqOffset   int32
	pendingAudioRebase bool

	// Per-source keyframe readiness signalling for zero-freeze switching.
	keyframeCh map[string]chan struct{}
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
	b.keyframeCh = make(map[string]chan struct{})
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

	connected := make([]string, 0, len(sorted))
	firstConnected := true
	for i, cam := range sorted {
		log.Printf("[bridge] connecting camera %d/%d: %s (first=%v)", i+1, len(sorted), cam, firstConnected)
		if err := b.connectCamera(cam, firstConnected); err != nil {
			// Don't fail startup if a camera path is missing/unpublished (for example 404).
			// Keep going with the cameras that are available.
			log.Printf("[bridge] camera %s connect FAILED (skipping): %v", cam, err)
			continue
		}
		connected = append(connected, cam)
		firstConnected = false
	}

	if len(connected) == 0 {
		b.Stop()
		return fmt.Errorf("no camera sources available")
	}

	activeAvailable := false
	for _, cam := range connected {
		if cam == active {
			activeAvailable = true
			break
		}
	}
	if !activeAvailable {
		fallback := connected[0]
		log.Printf("[bridge] active camera %s unavailable, falling back to %s", active, fallback)
		b.mu.Lock()
		b.active = fallback
		b.mu.Unlock()
	}

	// Start reconnect monitors for each camera
	b.cameras = connected
	for i, cam := range connected {
		go b.monitorCamera(i, cam)
	}

	log.Printf("[bridge] started on rtsp://localhost%s/stream (%d cameras, active: %s)",
		b.addr, len(connected), b.active)

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
	// Also build a payload type mapping so incoming packets use the server's PT.
	mediaMap := make(map[*description.Media]*description.Media)
	ptMap := make(map[uint8]uint8) // client PT → server PT
	for _, cm := range desc.Medias {
		for _, sm := range b.serverMedias {
			if cm.Type == sm.Type {
				mediaMap[cm] = sm
				// Map payload types: use first format from each side
				if len(cm.Formats) > 0 && len(sm.Formats) > 0 {
					clientPT := cm.Formats[0].PayloadType()
					serverPT := sm.Formats[0].PayloadType()
					if clientPT != serverPT {
						ptMap[clientPT] = serverPT
						log.Printf("[bridge] connectCamera %s: PT remap %s %d → %d", name, cm.Type, clientPT, serverPT)
					}
				}
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
			// Detect keyframes from non-active sources for pre-switch readiness
			if medi.Type == description.MediaTypeVideo && isH264Keyframe(pkt) {
				b.mu.Lock()
				if ch, ok := b.keyframeCh[camName]; ok {
					select {
					case <-ch:
					default:
						close(ch)
					}
				}
				b.mu.Unlock()
			}
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
				if b.pendingAudioRebase {
					b.audioTSOffset = int64(b.lastAudioTS) - int64(pkt.Timestamp) + 1024
					b.audioSeqOffset = int32(b.lastAudioSeq) - int32(pkt.SequenceNumber) + 1
					b.pendingAudioRebase = false
				}
				pkt.Timestamp = uint32(int64(pkt.Timestamp) + b.audioTSOffset)
				pkt.SequenceNumber = uint16(int32(pkt.SequenceNumber) + b.audioSeqOffset)
				b.lastAudioTS = pkt.Timestamp
				b.lastAudioSeq = pkt.SequenceNumber
			}
			b.mu.Unlock()
			// Remap payload type if client/server differ
			if newPT, ok := ptMap[pkt.PayloadType]; ok {
				pkt.PayloadType = newPT
			}
			if b.stream != nil {
				if err := b.stream.WritePacketRTP(sm, pkt); err != nil {
					log.Printf("bridge write error: %v", err)
				}
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
		if idx >= len(b.clients) || b.clients[idx] == nil {
			b.mu.RUnlock()
			return
		}
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
	ptMap := make(map[uint8]uint8)
	for _, cm := range desc.Medias {
		for _, sm := range serverMedias {
			if cm.Type == sm.Type {
				mediaMap[cm] = sm
				if len(cm.Formats) > 0 && len(sm.Formats) > 0 {
					clientPT := cm.Formats[0].PayloadType()
					serverPT := sm.Formats[0].PayloadType()
					if clientPT != serverPT {
						ptMap[clientPT] = serverPT
					}
				}
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
			// Detect keyframes from non-active sources for pre-switch readiness
			if medi.Type == description.MediaTypeVideo && isH264Keyframe(pkt) {
				b.mu.Lock()
				if ch, ok := b.keyframeCh[camName]; ok {
					select {
					case <-ch:
					default:
						close(ch)
					}
				}
				b.mu.Unlock()
			}
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
				if b.pendingAudioRebase {
					b.audioTSOffset = int64(b.lastAudioTS) - int64(pkt.Timestamp) + 1024
					b.audioSeqOffset = int32(b.lastAudioSeq) - int32(pkt.SequenceNumber) + 1
					b.pendingAudioRebase = false
				}
				pkt.Timestamp = uint32(int64(pkt.Timestamp) + b.audioTSOffset)
				pkt.SequenceNumber = uint16(int32(pkt.SequenceNumber) + b.audioSeqOffset)
				b.lastAudioTS = pkt.Timestamp
				b.lastAudioSeq = pkt.SequenceNumber
			}
			b.mu.Unlock()
			if newPT, ok := ptMap[pkt.PayloadType]; ok {
				pkt.PayloadType = newPT
			}
			if b.stream != nil {
				if err := b.stream.WritePacketRTP(sm, pkt); err != nil {
					log.Printf("bridge write error: %v", err)
				}
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
		b.pendingAudioRebase = true
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
	b.pendingAudioRebase = true
	b.switchTime = time.Now()
	b.droppedVideoPkts = 0
	b.mu.Unlock()

	log.Printf("[bridge] Switch: %s → %s (waiting for live keyframe)", old, camera)
}

// SwitchNoWait changes the active camera but skips the keyframe gate.
// Use after WaitForKeyframe has confirmed readiness — the next packet
// from the source will be at or near a keyframe boundary.
func (b *Bridge) SwitchNoWait(camera string) {
	b.mu.Lock()
	old := b.active
	b.active = camera
	b.needsKeyframe = false
	b.pendingVideoRebase = true
	b.pendingAudioRebase = true
	b.switchTime = time.Now()
	b.droppedVideoPkts = 0
	b.mu.Unlock()

	log.Printf("[bridge] SwitchNoWait: %s → %s (keyframe pre-confirmed)", old, camera)
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
		if c != nil {
			log.Printf("[bridge] Stop: closing client %d", i)
			c.Close()
		}
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

// ConnectSource dynamically connects to rtspBase/<name> as a new source.
// Used for ad playback — the ad is published to mediamtx, then connected
// to the bridge so it can be switched to like any camera.
func (b *Bridge) ConnectSource(name string) error {
	log.Printf("[bridge] ConnectSource: %s", name)
	b.mu.Lock()
	b.keyframeCh[name] = make(chan struct{})
	b.mu.Unlock()
	if err := b.connectCamera(name, false); err != nil {
		b.mu.Lock()
		delete(b.keyframeCh, name)
		b.mu.Unlock()
		return fmt.Errorf("connect source %s: %w", name, err)
	}
	b.mu.Lock()
	b.cameras = append(b.cameras, name)
	b.mu.Unlock()
	log.Printf("[bridge] ConnectSource: %s connected (total sources: %d)", name, len(b.cameras))
	return nil
}

// WaitForKeyframe blocks until a keyframe is received from the named source
// or the timeout expires. Returns true if a keyframe was seen.
func (b *Bridge) WaitForKeyframe(name string, timeout time.Duration) bool {
	b.mu.RLock()
	ch, ok := b.keyframeCh[name]
	b.mu.RUnlock()
	if !ok {
		return false
	}
	select {
	case <-ch:
		log.Printf("[bridge] WaitForKeyframe: %s keyframe ready", name)
		return true
	case <-time.After(timeout):
		log.Printf("[bridge] WaitForKeyframe: %s timed out after %v", name, timeout)
		return false
	}
}

// DisconnectSource disconnects a dynamically-added source by name.
// Sets the client slot to nil rather than removing it, to avoid shifting
// indices that monitorCamera goroutines depend on.
func (b *Bridge) DisconnectSource(name string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for i, cam := range b.cameras {
		if cam == name {
			if i < len(b.clients) && b.clients[i] != nil {
				b.clients[i].Close()
				b.clients[i] = nil
			}
			delete(b.keyframeCh, name)
			log.Printf("[bridge] DisconnectSource: %s closed (slot %d)", name, i)
			return
		}
	}
	log.Printf("[bridge] DisconnectSource: %s not found", name)
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
	b.pendingAudioRebase = false
	b.switchTime = time.Now()
	b.droppedVideoPkts = 0
	b.lastVideoTS = 0
	b.lastVideoSeq = 0
	b.videoTSOffset = 0
	b.videoSeqOffset = 0
	b.lastAudioTS = 0
	b.lastAudioSeq = 0
	b.audioTSOffset = 0
	b.audioSeqOffset = 0
	b.mu.Unlock()
	return &base.Response{StatusCode: base.StatusOK}, nil
}
