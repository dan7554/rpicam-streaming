package switcher

import (
	"os/exec"
	"testing"
)

// fakeCmdFactory returns a command that just sleeps (simulates ffmpeg running).
func fakeCmdFactory(rtspURL, rtmpURL, audioDevice string) *exec.Cmd {
	return exec.Command("sleep", "60")
}

// fakeBridge is a no-op bridge for tests.
type fakeBridge struct {
	active string
}

func (f *fakeBridge) Start(cameras []string, active string) error { f.active = active; return nil }
func (f *fakeBridge) Switch(camera string)                        { f.active = camera }
func (f *fakeBridge) ProxyURL() string                            { return "rtsp://localhost:8555/stream" }
func (f *fakeBridge) Stop()                                       {}

func fakeBridgeFactory() Bridger { return &fakeBridge{} }

func newTestSwitcher() *Switcher {
	return NewWithFactories("rtsp://localhost:8554", "http://localhost:9997", fakeCmdFactory, fakeBridgeFactory, []string{"cam1", "cam2", "cam3"})
}

func TestNew(t *testing.T) {
	sw := New("rtsp://localhost:8554", "http://localhost:9997", nil, nil)
	status := sw.Status()
	if status.Live {
		t.Error("new switcher should not be live")
	}
	if status.ActiveStream != "" {
		t.Errorf("expected empty active stream, got %q", status.ActiveStream)
	}
}

func TestStartLive(t *testing.T) {
	sw := newTestSwitcher()
	defer sw.StopAll()

	err := sw.StartLive("cam1", "test-key-123", false, "")
	if err != nil {
		t.Fatalf("StartLive failed: %v", err)
	}

	status := sw.Status()
	if !status.Live {
		t.Error("expected live=true after StartLive")
	}
	if status.ActiveStream != "cam1" {
		t.Errorf("expected active_stream=cam1, got %q", status.ActiveStream)
	}
}

func TestStartLiveAlreadyLive(t *testing.T) {
	sw := newTestSwitcher()
	defer sw.StopAll()

	_ = sw.StartLive("cam1", "test-key", false, "")

	err := sw.StartLive("cam2", "test-key", false, "")
	if err == nil {
		t.Error("expected error when starting live while already live")
	}
}

func TestStopLive(t *testing.T) {
	sw := newTestSwitcher()
	defer sw.StopAll()

	_ = sw.StartLive("cam1", "test-key", false, "")

	err := sw.StopLive()
	if err != nil {
		t.Fatalf("StopLive failed: %v", err)
	}

	status := sw.Status()
	if status.Live {
		t.Error("expected live=false after StopLive")
	}
	if status.ActiveStream != "" {
		t.Errorf("expected empty active stream after StopLive, got %q", status.ActiveStream)
	}
}

func TestStopLiveNotLive(t *testing.T) {
	sw := New("rtsp://localhost:8554", "http://localhost:9997", nil, nil)

	err := sw.StopLive()
	if err == nil {
		t.Error("expected error when stopping while not live")
	}
}

func TestSwitch(t *testing.T) {
	sw := newTestSwitcher()
	defer sw.StopAll()

	_ = sw.StartLive("cam1", "test-key", false, "")

	err := sw.Switch("cam2")
	if err != nil {
		t.Fatalf("Switch failed: %v", err)
	}

	status := sw.Status()
	if status.ActiveStream != "cam2" {
		t.Errorf("expected active_stream=cam2, got %q", status.ActiveStream)
	}
	if !status.Live {
		t.Error("should still be live after switch")
	}
}

func TestSwitchSameStream(t *testing.T) {
	sw := newTestSwitcher()
	defer sw.StopAll()

	_ = sw.StartLive("cam1", "test-key", false, "")

	err := sw.Switch("cam1")
	if err != nil {
		t.Fatalf("Switch to same stream should be no-op, got: %v", err)
	}
}

func TestSwitchNotLive(t *testing.T) {
	sw := New("rtsp://localhost:8554", "http://localhost:9997", nil, nil)

	err := sw.Switch("cam2")
	if err == nil {
		t.Error("expected error when switching while not live")
	}
}

func TestStopAll(t *testing.T) {
	sw := newTestSwitcher()

	_ = sw.StartLive("cam1", "test-key", false, "")
	sw.StopAll()

	// Should not panic on double StopAll
	sw.StopAll()
}

func TestFullLifecycle(t *testing.T) {
	sw := newTestSwitcher()
	defer sw.StopAll()

	// Start live on cam1
	if err := sw.StartLive("cam1", "key-abc", false, ""); err != nil {
		t.Fatalf("start live: %v", err)
	}

	// Switch to cam2
	if err := sw.Switch("cam2"); err != nil {
		t.Fatalf("switch to cam2: %v", err)
	}

	// Switch to cam3
	if err := sw.Switch("cam3"); err != nil {
		t.Fatalf("switch to cam3: %v", err)
	}

	status := sw.Status()
	if status.ActiveStream != "cam3" {
		t.Errorf("expected cam3, got %q", status.ActiveStream)
	}

	// Stop
	if err := sw.StopLive(); err != nil {
		t.Fatalf("stop live: %v", err)
	}

	// Start again on cam2
	if err := sw.StartLive("cam2", "key-xyz", false, ""); err != nil {
		t.Fatalf("restart live: %v", err)
	}

	status = sw.Status()
	if !status.Live || status.ActiveStream != "cam2" {
		t.Errorf("expected live=true, active=cam2, got live=%v, active=%q", status.Live, status.ActiveStream)
	}
}
