package switcher

import (
	"fmt"
	"log"
	"os"
	"os/exec"
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
	commentary      CommentaryConfig // live commentary mixing
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

// buildDefaultPipeline returns the GStreamer pipeline string for the default (no overlay) mode.
func buildDefaultPipeline(rtspURL, rtmpURL, audioDevice string) string {
	if audioDevice != "" {
		// Mac mic overrides camera audio
		return fmt.Sprintf(
			"rtspsrc location=%s protocols=tcp latency=200 name=src "+
				"osxaudiosrc device=%s name=mic "+
				"src. ! rtph264depay ! h264parse ! video/x-h264,stream-format=avc,alignment=au ! tee name=vt "+
				"mic. ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=1 ! audiorate ! tee name=at "+
				"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! audioconvert ! avenc_aac ! aacparse ! flvmux streamable=true name=flvm "+
				"vt. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! flvm. "+
				"flvm. ! rtmpsink location=%s "+
			"vt. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! rtspclientsink location=rtsp://localhost:8554/live-preview protocols=tcp name=preview "+
			"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! audioconvert ! opusenc audio-type=restricted-lowdelay ! preview.",
			rtspURL, audioDevice, rtmpURL)
	}
	// Camera audio from RTSP stream
	return fmt.Sprintf(
		"rtspsrc location=%s protocols=tcp latency=200 name=src "+
			"src. ! rtph264depay ! h264parse ! video/x-h264,stream-format=avc,alignment=au ! tee name=vt "+
			"src. ! rtpmp4gdepay ! aacparse ! avdec_aac ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=1 ! audiorate ! tee name=at "+
			"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! audioconvert ! avenc_aac ! aacparse ! flvmux streamable=true name=flvm "+
			"vt. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! flvm. "+
			"flvm. ! rtmpsink location=%s "+
		"vt. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! rtspclientsink location=rtsp://localhost:8554/live-preview protocols=tcp name=preview "+
		"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! audioconvert ! opusenc audio-type=restricted-lowdelay ! preview.",
		rtspURL, rtmpURL)
}

// buildOverlayPipeline returns the GStreamer pipeline string for overlay mode.
func buildOverlayPipeline(overlayPath, rtspURL, rtmpURL, audioDevice string) string {
	if audioDevice != "" {
		return fmt.Sprintf(
			"filesrc location=%s ! pngdec ! imagefreeze ! video/x-raw,framerate=30/1 ! queue name=overlay_img "+
				"rtspsrc location=%s protocols=tcp latency=200 name=cam "+
				"cam. ! rtph264depay ! h264parse ! video/x-h264,stream-format=avc,alignment=au ! avdec_h264 ! videoconvert ! video/x-raw,format=RGBA ! queue ! compositor name=mixer sink_1::xpos=20 sink_1::ypos=20 ! videoconvert ! x264enc tune=zerolatency speed-preset=ultrafast key-int-max=30 bframes=0 bitrate=4000 ! h264parse ! tee name=enc_tee "+
				"overlay_img. ! mixer. "+
				"enc_tee. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! flvmux streamable=true name=rtmp_mux "+
				"rtmp_mux. ! rtmpsink location=%s "+
				"osxaudiosrc device=%s ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=1 ! audiorate ! tee name=at "+
				"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! audioconvert ! avenc_aac ! aacparse ! rtmp_mux. "+
			"enc_tee. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! rtspclientsink location=rtsp://localhost:8554/live-preview protocols=tcp name=preview "+
			"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! audioconvert ! opusenc audio-type=restricted-lowdelay ! preview.",
			overlayPath, rtspURL, rtmpURL, audioDevice)
	}
	return fmt.Sprintf(
		"filesrc location=%s ! pngdec ! imagefreeze ! video/x-raw,framerate=30/1 ! queue name=overlay_img "+
			"rtspsrc location=%s protocols=tcp latency=200 name=cam "+
			"cam. ! rtph264depay ! h264parse ! video/x-h264,stream-format=avc,alignment=au ! avdec_h264 ! videoconvert ! video/x-raw,format=RGBA ! queue ! compositor name=mixer sink_1::xpos=20 sink_1::ypos=20 ! videoconvert ! x264enc tune=zerolatency speed-preset=ultrafast key-int-max=30 bframes=0 bitrate=4000 ! h264parse ! tee name=enc_tee "+
			"overlay_img. ! mixer. "+
			"enc_tee. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! flvmux streamable=true name=rtmp_mux "+
			"rtmp_mux. ! rtmpsink location=%s "+
			"cam. ! rtpmp4gdepay ! aacparse ! avdec_aac ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=1 ! audiorate ! tee name=at "+
			"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! audioconvert ! avenc_aac ! aacparse ! rtmp_mux. "+
		"enc_tee. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! rtspclientsink location=rtsp://localhost:8554/live-preview protocols=tcp name=preview "+
		"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! audioconvert ! opusenc audio-type=restricted-lowdelay ! preview.",
		overlayPath, rtspURL, rtmpURL)
}

func defaultCmdFactory(rtspURL, rtmpURL, audioDevice string) *exec.Cmd {
	log.Printf("[switcher] building GStreamer cmd: %s → %s + preview (audio=%q)", rtspURL, rtmpURL, audioDevice)
	pipeline := buildDefaultPipeline(rtspURL, rtmpURL, audioDevice)
	log.Printf("[switcher] GStreamer pipeline: %s", pipeline)
	args := append([]string{"-e"}, strings.Fields(pipeline)...)
	return exec.Command("gst-launch-1.0", args...)
}

func overlayCmdFactory(overlayPath string) CmdFactory {
	return func(rtspURL, rtmpURL, audioDevice string) *exec.Cmd {
		log.Printf("[switcher] building OVERLAY GStreamer cmd: %s → %s (overlay=%s audio=%q)", rtspURL, rtmpURL, overlayPath, audioDevice)
		pipeline := buildOverlayPipeline(overlayPath, rtspURL, rtmpURL, audioDevice)
		log.Printf("[switcher] GStreamer overlay pipeline: %s", pipeline)
		args := append([]string{"-e"}, strings.Fields(pipeline)...)
		return exec.Command("gst-launch-1.0", args...)
	}
}

func New(rtspBase, mediaMTXAPI string, bf BridgeFactory, cameras []string) *Switcher {
	log.Printf("[switcher] New: rtspBase=%s mediaMTXAPI=%s cameras=%v", rtspBase, mediaMTXAPI, cameras)
	return &Switcher{
		rtspBase:      rtspBase,
		mediaMTXAPI:   mediaMTXAPI,
		cmdFactory:    defaultCmdFactory,
		bridgeFactory: bf,
		cameras:       cameras,
		commentary: CommentaryConfig{
			CameraVolume: 0.3,
			Slots: []CommentarySlot{
				{Volume: 1.0},
				{Volume: 1.0},
			},
		},
	}
}

// SetOverlay enables/disables the PNG overlay. Restarts FFmpeg with the
// appropriate filter chain.
func (s *Switcher) SetOverlay(pngPath string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	log.Printf("[switcher] SetOverlay called: pngPath=%q live=%v localMode=%v activeStream=%s", pngPath, s.live, s.localMode, s.activeStream)
	if pngPath != "" {
		s.overlayPath = pngPath
		s.cmdFactory = overlayCmdFactory(pngPath)
		log.Printf("[switcher] overlay ENABLED → cmdFactory=overlay path=%s (live=%v active=%s localMode=%v)", pngPath, s.live, s.activeStream, s.localMode)
	} else {
		s.overlayPath = ""
		s.cmdFactory = defaultCmdFactory
		log.Printf("[switcher] overlay DISABLED → cmdFactory=default (live=%v active=%s localMode=%v)", s.live, s.activeStream, s.localMode)
	}
	// Restart FFmpeg with the new filter chain if currently live
	if s.live && !s.localMode {
		log.Printf("[switcher] restarting streaming process for overlay change (was live)...")
		oldCmd := s.cmd
		wasLive := s.live
		wasActiveStream := s.activeStream
		wasLocalMode := s.localMode
		log.Printf("[switcher] overlay restart details: oldPID=%v overlayPath=%s cmdFactory=%T", func() any { if oldCmd != nil && oldCmd.Process != nil { return oldCmd.Process.Pid }; return nil }(), s.overlayPath, s.cmdFactory)
		if err := s.startFFmpeg(); err != nil {
			log.Printf("[switcher] overlay restart FAILED, restoring previous process: %v", err)
			s.cmd = oldCmd
			s.live = wasLive
			s.activeStream = wasActiveStream
			s.localMode = wasLocalMode
			return
		}
		s.live = wasLive
		s.activeStream = wasActiveStream
		s.localMode = wasLocalMode
		if oldCmd != nil && oldCmd.Process != nil {
			log.Printf("[switcher] overlay restart succeeded, stopping old PID=%d", oldCmd.Process.Pid)
			if err := oldCmd.Process.Signal(os.Interrupt); err != nil {
				log.Printf("[switcher] old process SIGINT failed: %v, killing PID=%d", err, oldCmd.Process.Pid)
				_ = oldCmd.Process.Kill()
			}
		}
	} else {
		log.Printf("[switcher] not restarting FFmpeg (live=%v localMode=%v)", s.live, s.localMode)
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

// SetCommentary updates the commentary configuration and restarts the pipeline
// if currently live. Slots are initialized if not already set.
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

	// Restart pipeline if live
	if s.live && !s.localMode {
		log.Printf("[switcher] restarting pipeline for commentary change...")
		s.restartPipeline()
	}
}

// SetCommentarySlot updates a single commentary slot and restarts if needed.
func (s *Switcher) SetCommentarySlot(index int, active bool, volume float64) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if index < 0 || index >= len(s.commentary.Slots) {
		return fmt.Errorf("invalid slot index %d", index)
	}

	wasActive := s.hasActiveCommentary()
	s.commentary.Slots[index].Active = active
	s.commentary.Slots[index].Volume = volume
	nowActive := s.hasActiveCommentary()

	log.Printf("[switcher] SetCommentarySlot[%d]: active=%v volume=%.2f (wasActive=%v nowActive=%v)", index, active, volume, wasActive, nowActive)

	// Only restart if commentary state actually changed and we're live
	if s.live && !s.localMode && (wasActive != nowActive || (s.commentary.Enabled && nowActive)) {
		log.Printf("[switcher] restarting pipeline for commentary slot change...")
		s.restartPipeline()
	}
	return nil
}

// SetCommentaryVolume updates volume levels without restarting the pipeline
// if only volumes changed (pipeline restart needed for slot active/inactive changes).
func (s *Switcher) SetCommentaryVolume(cameraVol float64, slotVolumes []float64) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.commentary.CameraVolume = cameraVol
	for i, v := range slotVolumes {
		if i < len(s.commentary.Slots) {
			s.commentary.Slots[i].Volume = v
		}
	}

	// Volume changes require pipeline restart since we can't change
	// GStreamer element properties on a running gst-launch pipeline
	if s.live && !s.localMode && s.commentary.Enabled && s.hasActiveCommentary() {
		log.Printf("[switcher] restarting pipeline for volume change...")
		s.restartPipeline()
	}
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

	log.Printf("[switcher] startFFmpeg: %s → %s (active=%s overlayPath=%q audioDevice=%q commentary=%v)", rtspURL, rtmpURL, s.activeStream, s.overlayPath, s.audioDevice, s.commentary.Enabled)

	// Choose the appropriate cmd factory based on commentary state
	factory := s.cmdFactory
	if s.commentary.Enabled && s.hasActiveCommentary() {
		factory = commentaryCmdFactory(s.rtspBase, s.commentary, s.overlayPath)
	}
	s.cmd = factory(rtspURL, rtmpURL, s.audioDevice)
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
