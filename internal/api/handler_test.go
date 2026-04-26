package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os/exec"
	"strings"
	"testing"

	"github.com/dchristiani/media-mtx/internal/config"
	"github.com/dchristiani/media-mtx/internal/switcher"
)

func fakeCmdFactory(rtspURL, rtmpURL string) *exec.Cmd {
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

func fakeBridgeFactory() switcher.Bridger { return &fakeBridge{} }

func setup(t *testing.T) (http.Handler, *switcher.Switcher, *httptest.Server) {
	t.Helper()
	// Mock MediaMTX API
	mtxServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"itemCount":3,"items":[{"name":"cam1","ready":true},{"name":"cam2","ready":true},{"name":"cam3","ready":false}]}`))
	}))

	cfg := &config.Config{
		Port:         "8080",
		MediaMTXAPI:  mtxServer.URL,
		MediaMTXRTSP: "rtsp://localhost:8554",
		HLSAddress:   ":8888",
		RTMPOutput:   "rtmp://localhost:1935/live-output",
		BridgeAddr:   ":8555",
		Cameras:      []string{"cam1", "cam2", "cam3"},
	}
	sw := switcher.NewWithFactories(cfg.MediaMTXRTSP, cfg.MediaMTXAPI, fakeCmdFactory, fakeBridgeFactory, cfg.Cameras)
	handler := NewHandler(cfg, sw)
	return handler, sw, mtxServer
}

func TestGetStatus(t *testing.T) {
	handler, _, mtx := setup(t)
	defer mtx.Close()

	req := httptest.NewRequest("GET", "/api/status", nil)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var status switcher.Status
	json.Unmarshal(w.Body.Bytes(), &status)
	if status.Live {
		t.Error("expected live=false initially")
	}
}

func TestGetStreams(t *testing.T) {
	handler, _, mtx := setup(t)
	defer mtx.Close()

	req := httptest.NewRequest("GET", "/api/streams", nil)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var result map[string]any
	json.Unmarshal(w.Body.Bytes(), &result)
	if result["itemCount"] != float64(3) {
		t.Errorf("expected 3 items, got %v", result["itemCount"])
	}
}

func TestGetStreamsMediaMTXDown(t *testing.T) {
	cfg := &config.Config{
		Port:         "8080",
		MediaMTXAPI:  "http://127.0.0.1:1", // unreachable
		MediaMTXRTSP: "rtsp://localhost:8554",
		HLSAddress:   ":8888",
		RTMPOutput:   "rtmp://localhost:1935/live-output",
		BridgeAddr:   ":8555",
		Cameras:      []string{"cam1", "cam2", "cam3"},
	}
	sw := switcher.New(cfg.MediaMTXRTSP, cfg.MediaMTXAPI, nil, nil)
	handler := NewHandler(cfg, sw)

	req := httptest.NewRequest("GET", "/api/streams", nil)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusBadGateway {
		t.Fatalf("expected 502, got %d", w.Code)
	}
}

func TestStartLive(t *testing.T) {
	handler, sw, mtx := setup(t)
	defer mtx.Close()
	defer sw.StopAll()

	body := `{"stream":"cam1"}`
	req := httptest.NewRequest("POST", "/api/live/start", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var result map[string]string
	json.Unmarshal(w.Body.Bytes(), &result)
	if result["status"] != "live" {
		t.Errorf("expected status=live, got %q", result["status"])
	}
	if result["rtmp_dest"] != "rtmp://localhost:1935/live-output" {
		t.Errorf("expected local rtmp dest, got %q", result["rtmp_dest"])
	}
}

func TestStartLiveDefaultsStream(t *testing.T) {
	handler, sw, mtx := setup(t)
	defer mtx.Close()
	defer sw.StopAll()

	body := `{"youtube_key":"test-key-123"}`
	req := httptest.NewRequest("POST", "/api/live/start", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var result map[string]string
	json.Unmarshal(w.Body.Bytes(), &result)
	if result["stream"] != "cam1" {
		t.Errorf("expected stream=cam1 as default, got %q", result["stream"])
	}
	if result["rtmp_dest"] != "rtmp://a.rtmp.youtube.com/live2/test-key-123" {
		t.Errorf("expected youtube rtmp dest, got %q", result["rtmp_dest"])
	}
}

func TestStartLiveMissingKey(t *testing.T) {
	handler, sw, mtx := setup(t)
	defer mtx.Close()
	defer sw.StopAll()

	// No youtube_key — should use local RTMP
	body := `{"stream":"cam1"}`
	req := httptest.NewRequest("POST", "/api/live/start", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 (local mode), got %d: %s", w.Code, w.Body.String())
	}
}

func TestStartLiveInvalidJSON(t *testing.T) {
	handler, _, mtx := setup(t)
	defer mtx.Close()

	req := httptest.NewRequest("POST", "/api/live/start", strings.NewReader("not json"))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", w.Code)
	}
}

func TestStopLive(t *testing.T) {
	handler, sw, mtx := setup(t)
	defer mtx.Close()
	defer sw.StopAll()

	// Start first
	body := `{"stream":"cam1","youtube_key":"test-key"}`
	req := httptest.NewRequest("POST", "/api/live/start", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	// Stop
	req = httptest.NewRequest("POST", "/api/live/stop", nil)
	w = httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
}

func TestStopLiveNotLive(t *testing.T) {
	handler, _, mtx := setup(t)
	defer mtx.Close()

	req := httptest.NewRequest("POST", "/api/live/stop", nil)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d", w.Code)
	}
}

func TestSwitchStream(t *testing.T) {
	handler, sw, mtx := setup(t)
	defer mtx.Close()
	defer sw.StopAll()

	// Start live first
	body := `{"stream":"cam1","youtube_key":"test-key"}`
	req := httptest.NewRequest("POST", "/api/live/start", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	// Switch to cam2
	body = `{"stream":"cam2"}`
	req = httptest.NewRequest("POST", "/api/switch", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w = httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var result map[string]string
	json.Unmarshal(w.Body.Bytes(), &result)
	if result["stream"] != "cam2" {
		t.Errorf("expected stream=cam2, got %q", result["stream"])
	}
}

func TestSwitchStreamMissingField(t *testing.T) {
	handler, sw, mtx := setup(t)
	defer mtx.Close()
	defer sw.StopAll()

	_ = sw.StartLive("cam1", "key", false)

	body := `{}`
	req := httptest.NewRequest("POST", "/api/switch", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", w.Code)
	}
}

func TestSwitchNotLive(t *testing.T) {
	handler, _, mtx := setup(t)
	defer mtx.Close()

	body := `{"stream":"cam2"}`
	req := httptest.NewRequest("POST", "/api/switch", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d", w.Code)
	}
}

func TestSwitchInvalidJSON(t *testing.T) {
	handler, _, mtx := setup(t)
	defer mtx.Close()

	req := httptest.NewRequest("POST", "/api/switch", strings.NewReader("{bad"))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", w.Code)
	}
}
