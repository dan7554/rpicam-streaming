package switcher

import (
	"fmt"
	"image"
	"image/png"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// CmdFactory builds the exec.Cmd for streaming. Override in tests.
type CmdFactory func(rtspURL, rtmpURL, audioDevice string) *exec.Cmd

// previewRTSPURL derives the RTSP preview URL from the RTMP output URL.
// e.g. rtmp://localhost:1935/live-output → rtsp://localhost:8554/live-preview
// For external YouTube URLs, falls back to local preview.
func previewRTSPURL(rtmpURL string) string {
	return "rtsp://localhost:8554/live-preview"
}

// Bridger abstracts the RTSP switching proxy for testing.
type Bridger interface {
	Start(cameras []string, active string) error
	Switch(camera string)
	ProxyURL() string
	Stop()
}

// BridgeFactory creates a Bridger on demand.
type BridgeFactory func() Bridger

// Switcher manages stream selection and optionally an FFmpeg process for
// pushing to external RTMP destinations. In local mode (no external RTMP),
// switching is instant — no FFmpeg needed. In RTMP mode, a bridge proxy
// handles zero-gap switching while FFmpeg reads from the bridge.
type Switcher struct {
	mu              sync.Mutex
	rtspBase        string
	mediaMTXAPI     string
	activeStream    string
	rtmpDest        string
	cmd             *exec.Cmd
	live            bool
	localMode       bool
	cmdFactory      CmdFactory
	cameras         []string
	bridgeFactory   BridgeFactory
	bridge          Bridger
	overlayPath     string // path to overlay PNG, empty = no overlay
	audioDevice     string // avfoundation audio device index, empty = anullsrc
	restartCount    int    // consecutive restart count for backoff
	restartBackoff  time.Duration
	commentary      CommentaryConfig   // live commentary mixing
	silenceProcs    []*exec.Cmd        // silence → UDP (one per slot)
	relayProcs      []*exec.Cmd        // UDP → commentary-N RTSP (always-on, one per slot)
	whipBridgeProcs []*exec.Cmd        // commentary-N-whip RTSP → UDP (active when commentator connected)
}

// CommentaryConfig holds the state for browser-based commentary mixing.
type CommentaryConfig struct {
	Enabled      bool    // whether commentary mixing is active
	Slots        []CommentarySlot
	CameraVolume float64 // 0.0–1.0, volume of camera/ambient audio
}

// CommentarySlot represents one commentator's audio feed.
type CommentarySlot struct {
	Active bool    // whether this slot has a connected commentator
	Volume float64 // 0.0–1.0
}

// overlayVideoSrc returns the multifilesrc-based overlay segment that re-reads
// the overlay PNG from disk. Combined with compositor, this allows hot-swapping
// overlays by simply writing a new PNG (or a transparent one to disable).
func overlayVideoSrc(overlayPath string) string {
	return fmt.Sprintf(
		"multifilesrc location=%s loop=true start-index=0 stop-index=0 caps=image/png,framerate=(fraction)1/2 ! "+
			"pngdec ! videoconvert ! video/x-raw,format=RGBA ! queue name=overlay_img",
		overlayPath)
}

// buildPipeline returns the GStreamer pipeline string. The pipeline always
// includes a compositor + multifilesrc overlay for zero-restart overlay toggling,
// and an audiomixer blending camera audio + 2 commentary RTSP sources for
// zero-restart commentary join/leave.
func buildPipeline(overlayPath, rtspURL, rtmpURL, audioDevice, rtspBase string, cameraVol float64) string {
	overlay := overlayVideoSrc(overlayPath)
	audioMix := alwaysOnAudioMix(rtspBase, cameraVol)
	if audioDevice != "" {
		// Mac mic overrides camera audio — not mixed with commentary
		return fmt.Sprintf(
			"%s "+
				"rtspsrc location=%s protocols=tcp latency=200 name=cam "+
				"cam. ! rtph264depay ! h264parse ! video/x-h264,stream-format=avc,alignment=au ! avdec_h264 ! videoconvert ! video/x-raw,format=RGBA ! queue ! compositor name=mixer sink_1::xpos=20 sink_1::ypos=20 ! videoconvert ! x264enc tune=zerolatency speed-preset=ultrafast key-int-max=30 bframes=0 bitrate=4000 ! h264parse ! tee name=enc_tee "+
				"overlay_img. ! mixer. "+
				"osxaudiosrc device=%s name=mic "+
				"mic. ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=1 ! audiorate ! tee name=at "+
				"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! audioconvert ! avenc_aac ! aacparse ! flvmux streamable=true name=rtmp_mux "+
				"enc_tee. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! rtmp_mux. "+
				"rtmp_mux. ! rtmpsink location=%s "+
			"enc_tee. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! rtspclientsink location=rtsp://localhost:8554/live-preview protocols=tcp name=preview "+
			"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! audioconvert ! opusenc audio-type=restricted-lowdelay ! preview.",
			overlay, rtspURL, audioDevice, rtmpURL)
	}
	// Camera audio from RTSP stream, blended with commentary via audiomixer
	return fmt.Sprintf(
		"%s "+
			"rtspsrc location=%s protocols=tcp latency=200 name=cam "+
			"cam. ! rtph264depay ! h264parse ! video/x-h264,stream-format=avc,alignment=au ! avdec_h264 ! videoconvert ! video/x-raw,format=RGBA ! queue ! compositor name=mixer sink_1::xpos=20 sink_1::ypos=20 ! videoconvert ! x264enc tune=zerolatency speed-preset=ultrafast key-int-max=30 bframes=0 bitrate=4000 ! h264parse ! tee name=enc_tee "+
			"overlay_img. ! mixer. "+
			"%s "+
			"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! audioconvert ! avenc_aac ! aacparse ! flvmux streamable=true name=rtmp_mux "+
			"enc_tee. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! rtmp_mux. "+
			"rtmp_mux. ! rtmpsink location=%s "+
		"enc_tee. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! rtspclientsink location=rtsp://localhost:8554/live-preview protocols=tcp name=preview "+
		"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! audioconvert ! opusenc audio-type=restricted-lowdelay ! preview.",
		overlay, rtspURL, audioMix, rtmpURL)
}

// alwaysOnAudioMix returns the GStreamer segment for audiomixer that always
// includes camera audio + 2 commentary RTSP sources. When no commentator is
// connected, the silence publisher on that path provides silent Opus frames.
func alwaysOnAudioMix(rtspBase string, cameraVol float64) string {
	return fmt.Sprintf(
		"cam. ! rtpmp4gdepay ! aacparse ! avdec_aac ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=1 ! volume name=camvol volume=%.2f ! audiomixer name=amix latency=200000000 "+
			"rtspsrc location=%s/commentary-1 protocols=tcp latency=200 name=comm1 "+
			"comm1. ! rtpopusdepay ! opusdec ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=1 ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! amix. "+
			"rtspsrc location=%s/commentary-2 protocols=tcp latency=200 name=comm2 "+
			"comm2. ! rtpopusdepay ! opusdec ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=1 ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! amix. "+
			"amix. ! audiorate ! tee name=at",
		cameraVol, rtspBase, rtspBase)
}

// writeTransparentPNG writes a 1x1 fully transparent PNG to the given path
// (atomic write via tmp + rename). Used to "disable" overlay without pipeline restart.
func writeTransparentPNG(path string) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	img := image.NewRGBA(image.Rect(0, 0, 1, 1)) // all zeros = fully transparent
	tmp := path + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if err := png.Encode(f, img); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	f.Close()
	return os.Rename(tmp, path)
}

func makeCmdFactory(overlayPath, rtspBase string, cameraVol float64) CmdFactory {
	return func(rtspURL, rtmpURL, audioDevice string) *exec.Cmd {
		log.Printf("[switcher] building GStreamer cmd: %s → %s + preview (overlay=%s audio=%q camVol=%.2f)", rtspURL, rtmpURL, overlayPath, audioDevice, cameraVol)
		pipeline := buildPipeline(overlayPath, rtspURL, rtmpURL, audioDevice, rtspBase, cameraVol)
		log.Printf("[switcher] GStreamer pipeline: %s", pipeline)
		args := append([]string{"-e"}, strings.Fields(pipeline)...)
		return exec.Command("gst-launch-1.0", args...)
	}
}

func New(rtspBase, mediaMTXAPI string, bf BridgeFactory, cameras []string, overlayDir string) *Switcher {
	overlayPngPath := filepath.Join(overlayDir, "timing.png")
	log.Printf("[switcher] New: rtspBase=%s mediaMTXAPI=%s cameras=%v overlayPath=%s", rtspBase, mediaMTXAPI, cameras, overlayPngPath)

	// Ensure transparent PNG exists so the always-on compositor has a valid file
	if err := writeTransparentPNG(overlayPngPath); err != nil {
		log.Printf("[switcher] WARNING: failed to write initial transparent PNG: %v", err)
	}

	cameraVol := 0.3
	s := &Switcher{
		rtspBase:      rtspBase,
		mediaMTXAPI:   mediaMTXAPI,
		overlayPath:   overlayPngPath,
		cmdFactory:    makeCmdFactory(overlayPngPath, rtspBase, cameraVol),
		bridgeFactory: bf,
		cameras:       cameras,
		silenceProcs:  make([]*exec.Cmd, 2),
		relayProcs:    make([]*exec.Cmd, 2),
		whipBridgeProcs: make([]*exec.Cmd, 2),
		commentary: CommentaryConfig{
			CameraVolume: cameraVol,
			Slots: []CommentarySlot{
				{Volume: 1.0},
				{Volume: 1.0},
			},
		},
	}

	// Start always-on UDP relays (udp:500X → commentary-N RTSP), then start
	// silence senders that feed silent Opus RTP to the same UDP ports.
	// The pipeline reads commentary-N, whose RTSP publisher (the relay) never changes.
	for i := 0; i < 2; i++ {
		s.startRelay(i)
	}
	// Small delay so relays register in MediaMTX before silence starts sending
	go func() {
		time.Sleep(1 * time.Second)
		s.mu.Lock()
		defer s.mu.Unlock()
		for i := 0; i < 2; i++ {
			s.startSilencePublisher(i)
		}
	}()

	return s
}

// commentaryUDPPort returns the UDP port for a commentary slot's audio relay.
func commentaryUDPPort(slot int) int {
	return 5001 + slot
}

// startSilencePublisher sends silent Opus RTP to the slot's UDP port.
// The always-on relay reads from this UDP port and publishes to commentary-N.
func (s *Switcher) startSilencePublisher(slot int) {
	port := commentaryUDPPort(slot)
	name := fmt.Sprintf("silence-udp-%d", slot)
	pipeline := fmt.Sprintf("audiotestsrc wave=silence is-live=true ! opusenc ! rtpopuspay pt=96 ! udpsink host=127.0.0.1 port=%d", port)
	args := append([]string{"-e"}, strings.Fields(pipeline)...)
	cmd := exec.Command("gst-launch-1.0", args...)
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		log.Printf("[switcher] silence %s FAILED to start: %v", name, err)
		return
	}
	s.silenceProcs[slot] = cmd
	log.Printf("[switcher] silence %s started PID=%d (udp port %d)", name, cmd.Process.Pid, port)

	// Monitor — auto-restart if it dies (unless a commentator's WHIP bridge is active)
	go func(slot int, cmd *exec.Cmd, name string) {
		err := cmd.Wait()
		log.Printf("[switcher] silence %s exited: %v", name, err)
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.commentary.Slots[slot].Active {
			log.Printf("[switcher] silence %s: commentator active, not restarting", name)
			s.silenceProcs[slot] = nil
			return
		}
		if s.silenceProcs[slot] == cmd {
			log.Printf("[switcher] restarting silence %s...", name)
			s.silenceProcs[slot] = nil
			s.startSilencePublisher(slot)
		}
	}(slot, cmd, name)
}

// stopSilencePublisher stops the silence publisher for a slot.
// Sets silenceProcs[slot] to nil to prevent auto-restart, then kills async.
func (s *Switcher) stopSilencePublisher(slot int) {
	if cmd := s.silenceProcs[slot]; cmd != nil && cmd.Process != nil {
		log.Printf("[switcher] stopping silence publisher slot %d PID=%d", slot, cmd.Process.Pid)
		s.silenceProcs[slot] = nil // prevent auto-restart by monitor goroutine
		go func() {
			cmd.Process.Signal(os.Interrupt)
			done := make(chan struct{})
			go func() {
				cmd.Wait()
				close(done)
			}()
			select {
			case <-done:
				log.Printf("[switcher] silence publisher slot %d stopped", slot)
			case <-time.After(3 * time.Second):
				log.Printf("[switcher] silence publisher slot %d kill (timeout)", slot)
				cmd.Process.Kill()
			}
		}()
	}
}

// restartSilencePublisher stops then starts the silence publisher for a slot.
func (s *Switcher) restartSilencePublisher(slot int) {
	s.stopSilencePublisher(slot)
	// Small delay so the old process fully exits
	go func() {
		time.Sleep(300 * time.Millisecond)
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.silenceProcs[slot] == nil && !s.commentary.Slots[slot].Active {
			s.startSilencePublisher(slot)
		}
	}()
}

// startRelay starts an always-on GStreamer process that reads Opus RTP from a
// UDP port and publishes to commentary-N via RTSP. This relay never stops —
// whoever sends UDP packets (silence or WHIP bridge) is transparent to it.
func (s *Switcher) startRelay(slot int) {
	port := commentaryUDPPort(slot)
	name := fmt.Sprintf("commentary-%d", slot+1)
	dest := fmt.Sprintf("rtsp://localhost:8554/%s", name)
	pipeline := fmt.Sprintf(
		"udpsrc port=%d caps=application/x-rtp,media=audio,encoding-name=OPUS,clock-rate=48000,payload=96 "+
			"! rtpjitterbuffer latency=200 ! rtpopusdepay ! opusparse ! rtspclientsink location=%s protocols=tcp",
		port, dest)
	args := append([]string{"-e"}, strings.Fields(pipeline)...)
	cmd := exec.Command("gst-launch-1.0", args...)
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		log.Printf("[switcher] relay %s FAILED to start: %v", name, err)
		return
	}
	s.relayProcs[slot] = cmd
	log.Printf("[switcher] relay %s started PID=%d (udp:%d → %s)", name, cmd.Process.Pid, port, dest)

	// Monitor — always restart the relay, it should run forever
	go func(slot int, cmd *exec.Cmd, name string) {
		err := cmd.Wait()
		log.Printf("[switcher] relay %s exited: %v", name, err)
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.relayProcs[slot] == cmd {
			log.Printf("[switcher] relay %s: restarting in 2s...", name)
			s.relayProcs[slot] = nil
			go func() {
				time.Sleep(2 * time.Second)
				s.mu.Lock()
				defer s.mu.Unlock()
				if s.relayProcs[slot] == nil {
					s.startRelay(slot)
				}
			}()
		}
	}(slot, cmd, name)
}

// stopRelay stops the relay process for a slot.
func (s *Switcher) stopRelay(slot int) {
	if cmd := s.relayProcs[slot]; cmd != nil && cmd.Process != nil {
		log.Printf("[switcher] stopping relay slot %d PID=%d", slot, cmd.Process.Pid)
		s.relayProcs[slot] = nil // prevent auto-restart
		go func() {
			cmd.Process.Signal(os.Interrupt)
			done := make(chan struct{})
			go func() {
				cmd.Wait()
				close(done)
			}()
			select {
			case <-done:
				log.Printf("[switcher] relay slot %d stopped", slot)
			case <-time.After(3 * time.Second):
				log.Printf("[switcher] relay slot %d kill (timeout)", slot)
				cmd.Process.Kill()
			}
		}()
	}
}

// startWhipBridge reads the WHIP commentator's audio from commentary-N-whip via
// RTSP and forwards it as RTP to the slot's UDP port. The always-on relay picks
// it up and publishes to commentary-N without any publisher change.
func (s *Switcher) startWhipBridge(slot int) {
	port := commentaryUDPPort(slot)
	name := fmt.Sprintf("whip-bridge-%d", slot)
	src := fmt.Sprintf("rtsp://localhost:8554/commentary-%d-whip", slot+1)
	pipeline := fmt.Sprintf(
		"rtspsrc location=%s protocols=tcp latency=100 name=rsrc "+
			"rsrc. ! udpsink host=127.0.0.1 port=%d",
		src, port)
	args := append([]string{"-e"}, strings.Fields(pipeline)...)
	cmd := exec.Command("gst-launch-1.0", args...)
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		log.Printf("[switcher] %s FAILED to start: %v", name, err)
		return
	}
	s.whipBridgeProcs[slot] = cmd
	log.Printf("[switcher] %s started PID=%d (%s → udp:%d)", name, cmd.Process.Pid, src, port)

	// Monitor — restart if it crashes while commentator is still active
	go func(slot int, cmd *exec.Cmd, name string) {
		err := cmd.Wait()
		log.Printf("[switcher] %s exited: %v", name, err)
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.commentary.Slots[slot].Active && s.whipBridgeProcs[slot] == cmd {
			log.Printf("[switcher] %s: commentator still active, restarting in 2s...", name)
			s.whipBridgeProcs[slot] = nil
			go func() {
				time.Sleep(2 * time.Second)
				s.mu.Lock()
				defer s.mu.Unlock()
				if s.commentary.Slots[slot].Active && s.whipBridgeProcs[slot] == nil {
					s.startWhipBridge(slot)
				}
			}()
		} else {
			s.whipBridgeProcs[slot] = nil
		}
	}(slot, cmd, name)
}

// stopWhipBridge stops the WHIP bridge process for a slot.
func (s *Switcher) stopWhipBridge(slot int) {
	if cmd := s.whipBridgeProcs[slot]; cmd != nil && cmd.Process != nil {
		log.Printf("[switcher] stopping whip-bridge slot %d PID=%d", slot, cmd.Process.Pid)
		s.whipBridgeProcs[slot] = nil
		go func() {
			cmd.Process.Signal(os.Interrupt)
			done := make(chan struct{})
			go func() {
				cmd.Wait()
				close(done)
			}()
			select {
			case <-done:
				log.Printf("[switcher] whip-bridge slot %d stopped", slot)
			case <-time.After(3 * time.Second):
				log.Printf("[switcher] whip-bridge slot %d kill (timeout)", slot)
				cmd.Process.Kill()
			}
		}()
	}
}

// SetOverlay enables/disables the PNG overlay. The pipeline always includes
// a compositor with multifilesrc, so toggling just writes a transparent PNG
// (disable) or lets the overlay service write real PNGs (enable).
// NO pipeline restart is needed.
func (s *Switcher) SetOverlay(pngPath string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	log.Printf("[switcher] SetOverlay called: pngPath=%q live=%v localMode=%v activeStream=%s", pngPath, s.live, s.localMode, s.activeStream)
	if pngPath != "" {
		// Overlay enabled — the overlay service writes real PNGs to overlayPath.
		// multifilesrc in the running pipeline will pick them up automatically.
		log.Printf("[switcher] overlay ENABLED (no pipeline restart needed)")
	} else {
		// Overlay disabled — write transparent PNG so compositor shows nothing.
		log.Printf("[switcher] overlay DISABLED, writing transparent PNG to %s", s.overlayPath)
		if err := writeTransparentPNG(s.overlayPath); err != nil {
			log.Printf("[switcher] WARNING: failed to write transparent PNG: %v", err)
		}
	}
}

// NewWithFactories creates a Switcher with custom factories (for testing).
func NewWithFactories(rtspBase, mediaMTXAPI string, cf CmdFactory, bf BridgeFactory, cameras []string) *Switcher {
	return &Switcher{
		rtspBase:      rtspBase,
		mediaMTXAPI:   mediaMTXAPI,
		cmdFactory:    cf,
		bridgeFactory: bf,
		cameras:       cameras,
	}
}

// Status returns the current state.
type Status struct {
	Live         bool   `json:"live"`
	ActiveStream string `json:"active_stream"`
	RTMPDest     string `json:"rtmp_dest,omitempty"`
	LocalMode    bool   `json:"local_mode"`
}

func (s *Switcher) Status() Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	st := Status{
		Live:         s.live,
		ActiveStream: s.activeStream,
		LocalMode:    s.localMode,
	}
	return st
}

// StartLive begins streaming. In local mode, no FFmpeg is started — switching
// is instant. In RTMP mode, starts the bridge proxy and FFmpeg.
func (s *Switcher) StartLive(stream, rtmpDest string, localMode bool, audioDevice string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	log.Printf("[switcher] StartLive called: stream=%s rtmpDest=%s localMode=%v audioDevice=%q", stream, rtmpDest, localMode, audioDevice)

	if s.live {
		log.Printf("[switcher] StartLive REJECTED: already live")
		return fmt.Errorf("already live, stop first")
	}

	s.rtmpDest = rtmpDest
	s.activeStream = stream
	s.localMode = localMode
	s.audioDevice = audioDevice
	s.restartCount = 0
	s.restartBackoff = 0

	if localMode {
		log.Printf("[switcher] started live (local mode): %s", stream)
		s.live = true
		return nil
	}

	// RTMP mode: start bridge proxy, then FFmpeg
	log.Printf("[switcher] starting RTMP mode: bridge + FFmpeg")

	// Rebuild cmdFactory with current camera volume (may have changed since init)
	s.cmdFactory = makeCmdFactory(s.overlayPath, s.rtspBase, s.commentary.CameraVolume)

	if s.bridgeFactory != nil {
		log.Printf("[switcher] creating bridge proxy...")
		s.bridge = s.bridgeFactory()
		if err := s.bridge.Start(s.cameras, stream); err != nil {
			log.Printf("[switcher] bridge start FAILED: %v", err)
			return fmt.Errorf("bridge start: %w", err)
		}
		log.Printf("[switcher] bridge proxy started, URL=%s", s.bridge.ProxyURL())
	}

	if err := s.startFFmpeg(); err != nil {
		log.Printf("[switcher] FFmpeg start FAILED: %v, stopping bridge", err)
		if s.bridge != nil {
			s.bridge.Stop()
			s.bridge = nil
		}
		return err
	}
	s.live = true
	log.Printf("[switcher] now LIVE: stream=%s dest=%s", stream, rtmpDest)
	return nil
}

// StopLive stops the live session.
func (s *Switcher) StopLive() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	log.Printf("[switcher] StopLive called: live=%v localMode=%v activeStream=%s", s.live, s.localMode, s.activeStream)

	if !s.live {
		log.Printf("[switcher] StopLive REJECTED: not currently live")
		return fmt.Errorf("not currently live")
	}

	if !s.localMode {
		log.Printf("[switcher] stopping FFmpeg and bridge...")
		s.stopFFmpeg()
		if s.bridge != nil {
			s.bridge.Stop()
			s.bridge = nil
		}
	}
	s.live = false
	s.activeStream = ""
	s.localMode = false
	log.Printf("[switcher] live session STOPPED")
	return nil
}

// Switch changes the active stream. In local mode, this is instant.
// In RTMP mode, the bridge proxy atomically changes which camera's
// packets are forwarded — zero-gap switch.
func (s *Switcher) Switch(stream string) error {
	lockStart := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	lockWait := time.Since(lockStart)

	log.Printf("[switcher] Switch called: %s → %s (live=%v, lock_wait=%dms)", s.activeStream, stream, s.live, lockWait.Milliseconds())

	if !s.live {
		log.Printf("[switcher] Switch REJECTED: not live")
		return fmt.Errorf("not currently live, start live first")
	}

	if stream == s.activeStream {
		log.Printf("[switcher] Switch NOOP: already on %s", stream)
		return nil
	}

	if !s.localMode && s.bridge != nil {
		log.Printf("[switcher] delegating switch to bridge: %s", stream)
		bridgeStart := time.Now()
		s.bridge.Switch(stream)
		log.Printf("[switcher] bridge.Switch() took %dms", time.Since(bridgeStart).Milliseconds())
	}

	s.activeStream = stream
	log.Printf("[switcher] switched to %s", stream)
	return nil
}

// StopAll cleans up on shutdown.
func (s *Switcher) StopAll() {
	s.mu.Lock()
	defer s.mu.Unlock()
	log.Printf("[switcher] StopAll: shutting down everything")
	s.stopFFmpeg()
	if s.bridge != nil {
		s.bridge.Stop()
		s.bridge = nil
	}
	// Stop silence publishers, relays, and WHIP bridges
	for i := range s.silenceProcs {
		s.stopSilencePublisher(i)
		s.stopRelay(i)
		s.stopWhipBridge(i)
	}
	log.Printf("[switcher] StopAll complete")
}

// hasActiveCommentary returns true if any commentary slot is active.
func (s *Switcher) hasActiveCommentary() bool {
	for _, slot := range s.commentary.Slots {
		if slot.Active {
			return true
		}
	}
	return false
}

// CommentaryStatus returns the current commentary configuration.
func (s *Switcher) CommentaryStatus() CommentaryConfig {
	s.mu.Lock()
	defer s.mu.Unlock()
	// Return a copy
	cc := s.commentary
	cc.Slots = make([]CommentarySlot, len(s.commentary.Slots))
	copy(cc.Slots, s.commentary.Slots)
	return cc
}

// SetCommentary updates the commentary configuration.
// No pipeline restart needed — commentary audio paths are always connected.
func (s *Switcher) SetCommentary(cc CommentaryConfig) {
	s.mu.Lock()
	defer s.mu.Unlock()

	log.Printf("[switcher] SetCommentary: enabled=%v cameraVol=%.2f slots=%d", cc.Enabled, cc.CameraVolume, len(cc.Slots))

	// Initialize 2 slots if none provided
	if len(cc.Slots) == 0 {
		cc.Slots = []CommentarySlot{
			{Active: false, Volume: 1.0},
			{Active: false, Volume: 1.0},
		}
	}

	s.commentary = cc
	// No pipeline restart needed — audiomixer with commentary sources is always on
}

// SetCommentarySlot updates a single commentary slot.
// When a slot becomes inactive (commentator left), restart the silence
// publisher for that slot so the pipeline keeps getting audio frames.
func (s *Switcher) SetCommentarySlot(index int, active bool, volume float64) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if index < 0 || index >= len(s.commentary.Slots) {
		return fmt.Errorf("invalid slot index %d", index)
	}

	wasActive := s.commentary.Slots[index].Active
	s.commentary.Slots[index].Active = active
	s.commentary.Slots[index].Volume = volume

	log.Printf("[switcher] SetCommentarySlot[%d]: active=%v volume=%.2f (was=%v)", index, active, volume, wasActive)

	// When a commentator leaves, stop WHIP bridge and restart silence sender.
	// The relay stays running — it just receives silence UDP packets again.
	if wasActive && !active {
		log.Printf("[switcher] commentator left slot %d, stopping whip bridge, restarting silence", index)
		s.stopWhipBridge(index)
		s.restartSilencePublisher(index)
	}
	// When a commentator joins, stop the silence sender and start the WHIP
	// bridge that reads commentary-N-whip and sends to the same UDP port.
	// The relay stays running throughout — no publisher change on commentary-N.
	if !wasActive && active {
		log.Printf("[switcher] commentator joined slot %d, stopping silence, starting whip bridge", index)
		s.stopSilencePublisher(index)
		// Small delay to let WHIP session fully register in MediaMTX
		go func() {
			time.Sleep(500 * time.Millisecond)
			s.mu.Lock()
			defer s.mu.Unlock()
			if s.commentary.Slots[index].Active && s.whipBridgeProcs[index] == nil {
				s.startWhipBridge(index)
			}
		}()
	}

	return nil
}

// SetCommentaryVolume updates the camera volume level.
// No pipeline restart needed — volume is just metadata for next pipeline start.
func (s *Switcher) SetCommentaryVolume(cameraVol float64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.commentary.CameraVolume = cameraVol
	log.Printf("[switcher] SetCommentaryVolume: cameraVol=%.2f (applied at next pipeline start)", cameraVol)
}

// restartPipeline stops the current pipeline and starts a new one.
// Must be called with s.mu held.
func (s *Switcher) restartPipeline() {
	oldCmd := s.cmd
	if err := s.startFFmpeg(); err != nil {
		log.Printf("[switcher] pipeline restart FAILED: %v", err)
		s.cmd = oldCmd
		return
	}
	if oldCmd != nil && oldCmd.Process != nil {
		log.Printf("[switcher] stopping old pipeline PID=%d", oldCmd.Process.Pid)
		if err := oldCmd.Process.Signal(os.Interrupt); err != nil {
			_ = oldCmd.Process.Kill()
		}
	}
}

func (s *Switcher) startFFmpeg() error {
	// Read from bridge proxy if available, otherwise fallback to direct RTSP
	var rtspURL string
	if s.bridge != nil {
		rtspURL = s.bridge.ProxyURL()
		log.Printf("[switcher] startFFmpeg: using bridge proxy URL=%s", rtspURL)
	} else {
		rtspURL = fmt.Sprintf("%s/program", s.rtspBase)
		log.Printf("[switcher] startFFmpeg: using direct RTSP URL=%s", rtspURL)
	}
	rtmpURL := s.rtmpDest

	log.Printf("[switcher] startFFmpeg: %s → %s (active=%s overlayPath=%q audioDevice=%q)", rtspURL, rtmpURL, s.activeStream, s.overlayPath, s.audioDevice)

	s.cmd = s.cmdFactory(rtspURL, rtmpURL, s.audioDevice)
	s.cmd.Stderr = os.Stderr

	log.Printf("[switcher] startFFmpeg: launching process %q with args: %v", s.cmd.Path, s.cmd.Args)

	if err := s.cmd.Start(); err != nil {
		log.Printf("[switcher] startFFmpeg: FAILED to start: %v", err)
		return fmt.Errorf("ffmpeg start failed: %w", err)
	}

	log.Printf("[switcher] startFFmpeg: FFmpeg started, PID=%d", s.cmd.Process.Pid)

	// Monitor in background — auto-restart if FFmpeg exits while still live
	cmd := s.cmd
	pid := cmd.Process.Pid
	startedAt := time.Now()
	go func() {
		log.Printf("[switcher] monitor: watching FFmpeg PID=%d", pid)
		err := cmd.Wait()
		uptime := time.Since(startedAt)
		if err != nil {
			log.Printf("[switcher] monitor: FFmpeg PID=%d exited with error after %s: %v", pid, uptime.Round(time.Second), err)
		} else {
			log.Printf("[switcher] monitor: FFmpeg PID=%d exited cleanly after %s", pid, uptime.Round(time.Second))
		}

		s.mu.Lock()
		// Only restart if we're still live and this is still the current cmd
		// (not killed by stopFFmpeg)
		if s.live && s.cmd == cmd {
			// Reset backoff if pipeline ran for >60s (was stable)
			if uptime > 60*time.Second {
				s.restartCount = 0
				s.restartBackoff = 0
			}
			s.restartCount++
			// Exponential backoff: 2s, 4s, 8s, 16s, 30s max
			backoff := time.Duration(1<<uint(s.restartCount)) * time.Second
			if backoff > 30*time.Second {
				backoff = 30 * time.Second
			}
			s.restartBackoff = backoff

			log.Printf("[switcher] monitor: FFmpeg PID=%d crashed while live (restart #%d, backoff %s)", pid, s.restartCount, backoff)
			s.cmd = nil
			s.mu.Unlock()

			time.Sleep(backoff)

			s.mu.Lock()
			if s.live {
				log.Printf("[switcher] monitor: attempting FFmpeg restart #%d...", s.restartCount)
				if err := s.startFFmpeg(); err != nil {
					log.Printf("[switcher] monitor: FFmpeg restart FAILED: %v", err)
				}
			} else {
				log.Printf("[switcher] monitor: no longer live, skipping restart")
			}
			s.mu.Unlock()
		} else {
			log.Printf("[switcher] monitor: FFmpeg PID=%d exit was intentional (cmd replaced or not live)", pid)
			s.mu.Unlock()
		}
	}()

	return nil
}

func (s *Switcher) stopFFmpeg() {
	if s.cmd != nil && s.cmd.Process != nil {
		pid := s.cmd.Process.Pid
		log.Printf("[switcher] stopFFmpeg: stopping PID=%d", pid)
		cmd := s.cmd
		s.cmd = nil // clear before kill so monitor goroutine knows it was intentional
		// Send SIGINT first (allows GStreamer EOS / FFmpeg clean shutdown)
		if err := cmd.Process.Signal(os.Interrupt); err != nil {
			log.Printf("[switcher] stopFFmpeg: SIGINT PID=%d error: %v, trying SIGKILL", pid, err)
			cmd.Process.Kill()
		} else {
			// Give it a moment to shut down, then force-kill if still running
			go func() {
				time.Sleep(3 * time.Second)
				cmd.Process.Kill() // no-op if already exited
			}()
		}
	} else {
		log.Printf("[switcher] stopFFmpeg: no running process to stop")
	}
}
