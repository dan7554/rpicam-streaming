package api

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"

	"github.com/dchristiani/media-mtx/internal/config"
	"github.com/dchristiani/media-mtx/internal/overlay"
	"github.com/dchristiani/media-mtx/internal/switcher"
)

type Handler struct {
	cfg      *config.Config
	sw       *switcher.Switcher
	mux      *http.ServeMux
	hlsProxy *httputil.ReverseProxy
	overlay  *overlay.Overlay
}

func NewHandler(cfg *config.Config, sw *switcher.Switcher) *Handler {
	h := &Handler{cfg: cfg, sw: sw, mux: http.NewServeMux()}

	hlsURL, _ := url.Parse("http://localhost" + cfg.HLSAddress)
	h.hlsProxy = httputil.NewSingleHostReverseProxy(hlsURL)

	h.routes()
	return h
}

func (h *Handler) routes() {
	// API routes
	h.mux.HandleFunc("GET /api/streams", h.getStreams)
	h.mux.HandleFunc("GET /api/status", h.getStatus)
	h.mux.HandleFunc("POST /api/switch", h.switchStream)
	h.mux.HandleFunc("POST /api/live/start", h.startLive)
	h.mux.HandleFunc("POST /api/live/stop", h.stopLive)
	h.mux.HandleFunc("POST /api/overlay/start", h.startOverlay)
	h.mux.HandleFunc("POST /api/overlay/stop", h.stopOverlay)
	h.mux.HandleFunc("GET /api/overlay/status", h.overlayStatus)

	// Serve web UI
	h.mux.Handle("GET /", http.FileServer(http.Dir("web")))
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// HLS reverse proxy — intercept before mux
	if len(r.URL.Path) >= 5 && r.URL.Path[:5] == "/hls/" {
		r.URL.Path = r.URL.Path[4:] // strip /hls prefix, keep leading /
		h.hlsProxy.ServeHTTP(w, r)
		return
	}
	h.mux.ServeHTTP(w, r)
}

// getStreams queries MediaMTX API for active paths.
func (h *Handler) getStreams(w http.ResponseWriter, r *http.Request) {
	resp, err := http.Get(h.cfg.MediaMTXAPI + "/v3/paths/list")
	if err != nil {
		writeError(w, http.StatusBadGateway, "cannot reach MediaMTX: %v", err)
		return
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}

// getStatus returns current switcher state.
func (h *Handler) getStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, h.sw.Status())
}

type switchReq struct {
	Stream string `json:"stream"`
}

func (h *Handler) switchStream(w http.ResponseWriter, r *http.Request) {
	var req switchReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}
	if req.Stream == "" {
		writeError(w, http.StatusBadRequest, "stream is required")
		return
	}

	if err := h.sw.Switch(req.Stream); err != nil {
		writeError(w, http.StatusConflict, "%v", err)
		return
	}

	log.Printf("Switched to stream: %s", req.Stream)
	writeJSON(w, http.StatusOK, map[string]string{"status": "switched", "stream": req.Stream})
}

type liveStartReq struct {
	Stream     string `json:"stream"`
	YouTubeKey string `json:"youtube_key"`
	RTMPDest   string `json:"rtmp_dest"`
}

func (h *Handler) startLive(w http.ResponseWriter, r *http.Request) {
	var req liveStartReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}
	if req.Stream == "" {
		req.Stream = "cam1"
	}

	// Determine RTMP destination: youtube key, explicit URL, or local default
	rtmpDest := h.cfg.RTMPOutput // default: local MediaMTX
	localMode := true
	if req.YouTubeKey != "" {
		rtmpDest = "rtmp://a.rtmp.youtube.com/live2/" + req.YouTubeKey
		localMode = false
	} else if req.RTMPDest != "" {
		rtmpDest = req.RTMPDest
		localMode = false
	}

	if err := h.sw.StartLive(req.Stream, rtmpDest, localMode); err != nil {
		writeError(w, http.StatusConflict, "%v", err)
		return
	}

	log.Printf("Started live: %s → %s", req.Stream, rtmpDest)
	writeJSON(w, http.StatusOK, map[string]string{"status": "live", "stream": req.Stream, "rtmp_dest": rtmpDest})
}

func (h *Handler) stopLive(w http.ResponseWriter, r *http.Request) {
	if err := h.sw.StopLive(); err != nil {
		writeError(w, http.StatusConflict, "%v", err)
		return
	}

	log.Printf("Stopped live stream")
	writeJSON(w, http.StatusOK, map[string]string{"status": "stopped"})
}

type overlayStartReq struct {
	EventID   string `json:"event_id"`
	SessionID string `json:"session_id"` // optional — uses /active if empty
	MaxRows   int    `json:"max_rows"`
}

func (h *Handler) startOverlay(w http.ResponseWriter, r *http.Request) {
	var req overlayStartReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}
	if req.EventID == "" {
		writeError(w, http.StatusBadRequest, "event_id required")
		return
	}

	// Stop existing overlay
	if h.overlay != nil {
		h.overlay.Stop()
		h.overlay = nil
	}

	// Ensure overlay dir exists
	if err := os.MkdirAll(h.cfg.OverlayDir, 0755); err != nil {
		writeError(w, http.StatusInternalServerError, "overlay dir: %v", err)
		return
	}

	pngPath := filepath.Join(h.cfg.OverlayDir, "timing.png")

	h.overlay = overlay.New(overlay.Config{
		EventID:   req.EventID,
		SessionID: req.SessionID,
		PNGPath:   pngPath,
		MaxRows:   req.MaxRows,
	})
	h.overlay.Start()

	// Tell the switcher to use the overlay
	h.sw.SetOverlay(pngPath)

	log.Printf("Overlay started: event=%s session=%s", req.EventID, req.SessionID)
	writeJSON(w, http.StatusOK, map[string]string{
		"status":   "started",
		"event_id": req.EventID,
		"png_path": pngPath,
	})
}

func (h *Handler) stopOverlay(w http.ResponseWriter, r *http.Request) {
	if h.overlay == nil {
		writeError(w, http.StatusConflict, "no overlay running")
		return
	}
	h.overlay.Stop()
	h.overlay = nil
	h.sw.SetOverlay("")

	log.Printf("Overlay stopped")
	writeJSON(w, http.StatusOK, map[string]string{"status": "stopped"})
}

func (h *Handler) overlayStatus(w http.ResponseWriter, r *http.Request) {
	if h.overlay == nil {
		writeJSON(w, http.StatusOK, map[string]any{"active": false})
		return
	}
	comps := h.overlay.Competitors()
	writeJSON(w, http.StatusOK, map[string]any{
		"active":      true,
		"competitors": len(comps),
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, format string, args ...any) {
	writeJSON(w, status, map[string]string{"error": fmt.Sprintf(format, args...)})
}
