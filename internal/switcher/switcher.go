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
	mu            sync.Mutex
	rtspBase      string
	mediaMTXAPI   string
	activeStream  string
	rtmpDest      string
	cmd           *exec.Cmd
	live          bool
	localMode     bool
	cmdFactory    CmdFactory
	cameras       []string
	bridgeFactory BridgeFactory
	bridge        Bridger
	overlayPath   string // path to overlay PNG, empty = no overlay
	audioDevice   string // avfoundation audio device index, empty = anullsrc
}

func defaultCmdFactory(rtspURL, rtmpURL, audioDevice string) *exec.Cmd {
	log.Printf("[switcher] building GStreamer cmd: %s → %s + preview (audio=%q)", rtspURL, rtmpURL, audioDevice)
	previewURL := previewRTSPURL(rtmpURL)

	// GStreamer pipeline: RTSP source → tee video/audio → dual output
	// Output 1: RTMP + H264 passthrough + AAC passthrough
	// Output 2: RTSP + H264 passthrough + Opus (decoded from AAC)
	// Video is never re-encoded, audio is decoded+re-encoded only for Opus output
	var pipeline string
	if audioDevice != "" {
		// Mac mic overrides camera audio
		pipeline = fmt.Sprintf(
			"rtspsrc location=%s protocols=tcp latency=200 name=src "+
				"osxaudiosrc device=%s name=mic "+
				"src. ! rtph264depay ! h264parse ! video/x-h264,stream-format=avc,alignment=au ! tee name=vt "+
				"mic. ! audioconvert ! audioresample ! tee name=at "+
				"vt. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 ! flvmux streamable=true name=flvm "+
				"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 ! avenc_aac ! aacparse ! flvm. "+
				"flvm. ! rtmp2sink location=%s "+
				"rtspclientsink location=%s protocols=tcp name=rsink "+
				"vt. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 ! rsink. "+
				"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 ! opusenc bitrate=128000 ! rsink.",
			rtspURL, audioDevice, rtmpURL, previewURL)
	} else {
		// Camera audio from RTSP stream
		pipeline = fmt.Sprintf(
			"rtspsrc location=%s protocols=tcp latency=200 name=src "+
				"src. ! rtph264depay ! h264parse ! video/x-h264,stream-format=avc,alignment=au ! tee name=vt "+
				"src. ! rtpmp4gdepay ! aacparse ! tee name=at "+
				"vt. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 ! flvmux streamable=true name=flvm "+
				"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 ! flvm. "+
				"flvm. ! rtmp2sink location=%s "+
				"rtspclientsink location=%s protocols=tcp name=rsink "+
				"vt. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 ! rsink. "+
				"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 ! avdec_aac ! audioconvert ! audioresample ! opusenc bitrate=128000 ! rsink.",
			rtspURL, rtmpURL, previewURL)
	}

	log.Printf("[switcher] GStreamer pipeline: %s", pipeline)
	args := append([]string{"-e"}, strings.Fields(pipeline)...)
	return exec.Command("gst-launch-1.0", args...)
}

func overlayCmdFactory(overlayPath string) CmdFactory {
	return func(rtspURL, rtmpURL, audioDevice string) *exec.Cmd {
		log.Printf("[switcher] building OVERLAY FFmpeg cmd: %s → %s (overlay=%s audio=%q)", rtspURL, rtmpURL, overlayPath, audioDevice)

		args := []string{
			"-use_wallclock_as_timestamps", "1",
			"-probesize", "256000",
			"-analyzeduration", "500000",
			"-rtsp_transport", "tcp",
			"-fflags", "+nobuffer+discardcorrupt",
			"-err_detect", "ignore_err",
			"-i", rtspURL,
			"-loop", "1",
			"-f", "image2", "-r", "1",
			"-i", overlayPath,
		}

		var aMap string
		// Audio: avfoundation mic (stream 2) or camera audio from RTSP (stream 0)
		if audioDevice != "" {
			args = append(args, "-f", "avfoundation", "-i", ":"+audioDevice)
			args = append(args,
				"-filter_complex", "[1:v]format=rgba[ovr];[0:v][ovr]overlay=x=20:y=20:shortest=1[out]",
			)
			aMap = "2:a"
		} else {
			args = append(args,
				"-filter_complex", "[1:v]format=rgba[ovr];[0:v][ovr]overlay=x=20:y=20:shortest=1[out]",
			)
			aMap = "0:a?"
		}

		// Output 1: RTMP + AAC (YouTube / RTMP consumers)
		args = append(args,
			"-map", "[out]", "-map", aMap,
			"-c:v", "libx264",
			"-preset", "ultrafast",
			"-tune", "zerolatency",
			"-g", "30",
			"-keyint_min", "30",
			"-c:a", "aac", "-b:a", "128k",
			"-f", "flv", "-flvflags", "no_duration_filesize", "-flush_packets", "1",
			rtmpURL,
		)

		// Output 2: RTSP + Opus (WebRTC browser preview)
		previewURL := previewRTSPURL(rtmpURL)
		args = append(args,
			"-map", "[out]", "-map", aMap,
			"-c:v", "copy",
			"-c:a", "libopus", "-b:a", "128k",
			"-f", "rtsp", "-rtsp_transport", "tcp",
			previewURL,
		)

		return exec.Command("ffmpeg", args...)
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
		log.Printf("[switcher] overlay ENABLED → cmdFactory=overlay path=%s", pngPath)
	} else {
		s.overlayPath = ""
		s.cmdFactory = defaultCmdFactory
		log.Printf("[switcher] overlay DISABLED → cmdFactory=default")
	}
	// Restart FFmpeg with the new filter chain if currently live
	if s.live && !s.localMode {
		log.Printf("[switcher] restarting FFmpeg for overlay change (was live)...")
		s.stopFFmpeg()
		if err := s.startFFmpeg(); err != nil {
			log.Printf("[switcher] FFmpeg restart after overlay change FAILED: %v", err)
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
	log.Printf("[switcher] Status() → live=%v active=%s localMode=%v overlayPath=%q", st.Live, st.ActiveStream, st.LocalMode, s.overlayPath)
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
	s.mu.Lock()
	defer s.mu.Unlock()

	log.Printf("[switcher] Switch called: %s → %s (live=%v)", s.activeStream, stream, s.live)

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
		s.bridge.Switch(stream)
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

	log.Printf("[switcher] startFFmpeg: launching ffmpeg with args: %v", s.cmd.Args)

	if err := s.cmd.Start(); err != nil {
		log.Printf("[switcher] startFFmpeg: FAILED to start: %v", err)
		return fmt.Errorf("ffmpeg start failed: %w", err)
	}

	log.Printf("[switcher] startFFmpeg: FFmpeg started, PID=%d", s.cmd.Process.Pid)

	// Monitor in background — auto-restart if FFmpeg exits while still live
	cmd := s.cmd
	pid := cmd.Process.Pid
	go func() {
		log.Printf("[switcher] monitor: watching FFmpeg PID=%d", pid)
		err := cmd.Wait()
		if err != nil {
			log.Printf("[switcher] monitor: FFmpeg PID=%d exited with error: %v", pid, err)
		} else {
			log.Printf("[switcher] monitor: FFmpeg PID=%d exited cleanly", pid)
		}

		s.mu.Lock()
		// Only restart if we're still live and this is still the current cmd
		// (not killed by stopFFmpeg)
		if s.live && s.cmd == cmd {
			log.Printf("[switcher] monitor: FFmpeg PID=%d crashed while live, restarting in 2s...", pid)
			s.cmd = nil
			s.mu.Unlock()

			// Wait for MediaMTX to re-establish the program path source
			time.Sleep(2 * time.Second)

			s.mu.Lock()
			if s.live {
				log.Printf("[switcher] monitor: attempting FFmpeg restart after crash...")
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
