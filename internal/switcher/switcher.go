package switcher

import (
	"fmt"
	"log"
	"os/exec"
	"sync"
	"time"
)

// CmdFactory builds the exec.Cmd for streaming. Override in tests.
type CmdFactory func(rtspURL, rtmpURL string) *exec.Cmd

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
}

func defaultCmdFactory(rtspURL, rtmpURL string) *exec.Cmd {
	return exec.Command("ffmpeg",
		"-rtsp_transport", "tcp",
		"-i", rtspURL,
		"-c:v", "libx264",
		"-preset", "ultrafast",
		"-tune", "zerolatency",
		"-g", "60",
		"-keyint_min", "60",
		"-c:a", "aac",
		"-b:a", "128k",
		"-f", "flv",
		"-flvflags", "no_duration_filesize",
		rtmpURL,
	)
}

func New(rtspBase, mediaMTXAPI string, bf BridgeFactory, cameras []string) *Switcher {
	return &Switcher{
		rtspBase:      rtspBase,
		mediaMTXAPI:   mediaMTXAPI,
		cmdFactory:    defaultCmdFactory,
		bridgeFactory: bf,
		cameras:       cameras,
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
}

func (s *Switcher) Status() Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	return Status{
		Live:         s.live,
		ActiveStream: s.activeStream,
	}
}

// StartLive begins streaming. In local mode, no FFmpeg is started — switching
// is instant. In RTMP mode, starts the bridge proxy and FFmpeg.
func (s *Switcher) StartLive(stream, rtmpDest string, localMode bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.live {
		return fmt.Errorf("already live, stop first")
	}

	s.rtmpDest = rtmpDest
	s.activeStream = stream
	s.localMode = localMode

	if localMode {
		log.Printf("Started live (local): %s", stream)
		s.live = true
		return nil
	}

	// RTMP mode: start bridge proxy, then FFmpeg
	if s.bridgeFactory != nil {
		s.bridge = s.bridgeFactory()
		if err := s.bridge.Start(s.cameras, stream); err != nil {
			return fmt.Errorf("bridge start: %w", err)
		}
	}

	if err := s.startFFmpeg(); err != nil {
		if s.bridge != nil {
			s.bridge.Stop()
			s.bridge = nil
		}
		return err
	}
	s.live = true
	return nil
}

// StopLive stops the live session.
func (s *Switcher) StopLive() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.live {
		return fmt.Errorf("not currently live")
	}

	if !s.localMode {
		s.stopFFmpeg()
		if s.bridge != nil {
			s.bridge.Stop()
			s.bridge = nil
		}
	}
	s.live = false
	s.activeStream = ""
	s.localMode = false
	return nil
}

// Switch changes the active stream. In local mode, this is instant.
// In RTMP mode, the bridge proxy atomically changes which camera's
// packets are forwarded — zero-gap switch.
func (s *Switcher) Switch(stream string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.live {
		return fmt.Errorf("not currently live, start live first")
	}

	if stream == s.activeStream {
		return nil // already on this stream
	}

	if !s.localMode && s.bridge != nil {
		s.bridge.Switch(stream)
	}

	s.activeStream = stream
	return nil
}

// StopAll cleans up on shutdown.
func (s *Switcher) StopAll() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stopFFmpeg()
	if s.bridge != nil {
		s.bridge.Stop()
		s.bridge = nil
	}
}

func (s *Switcher) startFFmpeg() error {
	// Read from bridge proxy if available, otherwise fallback to direct RTSP
	var rtspURL string
	if s.bridge != nil {
		rtspURL = s.bridge.ProxyURL()
	} else {
		rtspURL = fmt.Sprintf("%s/program", s.rtspBase)
	}
	rtmpURL := s.rtmpDest

	log.Printf("Starting FFmpeg: %s → %s (active: %s)", rtspURL, rtmpURL, s.activeStream)

	s.cmd = s.cmdFactory(rtspURL, rtmpURL)

	if err := s.cmd.Start(); err != nil {
		return fmt.Errorf("ffmpeg start failed: %w", err)
	}

	// Monitor in background — auto-restart if FFmpeg exits while still live
	cmd := s.cmd
	go func() {
		err := cmd.Wait()
		if err != nil {
			log.Printf("FFmpeg exited: %v", err)
		}

		s.mu.Lock()
		// Only restart if we're still live and this is still the current cmd
		// (not killed by stopFFmpeg)
		if s.live && s.cmd == cmd {
			log.Printf("FFmpeg crashed while live, restarting in 2s...")
			s.cmd = nil
			s.mu.Unlock()

			// Wait for MediaMTX to re-establish the program path source
			time.Sleep(2 * time.Second)

			s.mu.Lock()
			if s.live {
				if err := s.startFFmpeg(); err != nil {
					log.Printf("FFmpeg restart failed: %v", err)
				}
			}
			s.mu.Unlock()
		} else {
			s.mu.Unlock()
		}
	}()

	return nil
}

func (s *Switcher) stopFFmpeg() {
	if s.cmd != nil && s.cmd.Process != nil {
		log.Printf("Stopping FFmpeg (PID %d)", s.cmd.Process.Pid)
		cmd := s.cmd
		s.cmd = nil // clear before kill so monitor goroutine knows it was intentional
		_ = cmd.Process.Kill()
	}
}
