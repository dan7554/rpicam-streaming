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
	"strings"

	"github.com/dchristiani/media-mtx/internal/config"
	"github.com/dchristiani/media-mtx/internal/overlay"
	"github.com/dchristiani/media-mtx/internal/switcher"
)

type Handler struct {
	cfg        *config.Config
	sw         *switcher.Switcher
	mux        *http.ServeMux
	hlsProxy   *httputil.ReverseProxy
	webrtcProxy *httputil.ReverseProxy
	overlay    *overlay.Overlay
}

func NewHandler(cfg *config.Config, sw *switcher.Switcher) *Handler {
	log.Printf("[api] NewHandler: port=%s hlsAddr=%s webrtcAddr=%s overlayDir=%s", cfg.Port, cfg.HLSAddress, cfg.WebRTCAddress, cfg.OverlayDir)
	h := &Handler{cfg: cfg, sw: sw, mux: http.NewServeMux()}

	hlsURL, _ := url.Parse("http://localhost" + cfg.HLSAddress)
	h.hlsProxy = httputil.NewSingleHostReverseProxy(hlsURL)

	webrtcURL, _ := url.Parse("http://localhost" + cfg.WebRTCAddress)
	h.webrtcProxy = httputil.NewSingleHostReverseProxy(webrtcURL)
	// Rewrite Location headers so WHEP session URLs go through the proxy
	h.webrtcProxy.ModifyResponse = func(resp *http.Response) error {
		if loc := resp.Header.Get("Location"); loc != "" {
			// Prefix /webrtc so the browser routes session URLs back through the proxy
			if len(loc) > 0 && loc[0] == '/' {
				resp.Header.Set("Location", "/webrtc"+loc)
			}
		}
		return nil
	}

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
		log.Printf("[api] HLS proxy: %s %s", r.Method, r.URL.Path)
		r.URL.Path = r.URL.Path[4:] // strip /hls prefix, keep leading /
		h.hlsProxy.ServeHTTP(w, r)
		return
	}
	// WebRTC/WHEP reverse proxy — for low-latency previews
	if len(r.URL.Path) >= 8 && r.URL.Path[:8] == "/webrtc/" {
		log.Printf("[api] WebRTC proxy: %s %s", r.Method, r.URL.Path)
		r.URL.Path = r.URL.Path[7:] // strip /webrtc prefix, keep leading /
		h.webrtcProxy.ServeHTTP(w, r)
		return
	}
	if strings.HasPrefix(r.URL.Path, "/api/") {
		log.Printf("[api] %s %s", r.Method, r.URL.Path)
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
		log.Printf("[api] switchStream: bad JSON: %v", err)
		writeError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}
	if req.Stream == "" {
		log.Printf("[api] switchStream: missing stream")
		writeError(w, http.StatusBadRequest, "stream is required")
		return
	}

	log.Printf("[api] switchStream: switching to %s", req.Stream)
	if err := h.sw.Switch(req.Stream); err != nil {
		log.Printf("[api] switchStream: FAILED: %v", err)
		writeError(w, http.StatusConflict, "%v", err)
		return
	}

	log.Printf("[api] switchStream: SUCCESS → %s", req.Stream)
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
		log.Printf("[api] startLive: bad JSON: %v", err)
		writeError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}
	if req.Stream == "" {
		req.Stream = "cam1"
	}

	// Determine RTMP destination: youtube key, explicit URL, or local default
	rtmpDest := h.cfg.RTMPOutput // default: local MediaMTX
	if req.YouTubeKey != "" {
		rtmpDest = "rtmp://a.rtmp.youtube.com/live2/" + req.YouTubeKey
	} else if req.RTMPDest != "" {
		rtmpDest = req.RTMPDest
	}

	log.Printf("[api] startLive: stream=%s rtmpDest=%s youtubeKey=%q", req.Stream, rtmpDest, req.YouTubeKey)

	// Always use FFmpeg mode so the composited live-output is available
	if err := h.sw.StartLive(req.Stream, rtmpDest, false); err != nil {
		log.Printf("[api] startLive: FAILED: %v", err)
		writeError(w, http.StatusConflict, "%v", err)
		return
	}

	log.Printf("[api] startLive: SUCCESS stream=%s dest=%s", req.Stream, rtmpDest)
	writeJSON(w, http.StatusOK, map[string]string{"status": "live", "stream": req.Stream, "rtmp_dest": rtmpDest})
}

func (h *Handler) stopLive(w http.ResponseWriter, r *http.Request) {
	log.Printf("[api] stopLive called")
	if err := h.sw.StopLive(); err != nil {
		log.Printf("[api] stopLive: FAILED: %v", err)
		writeError(w, http.StatusConflict, "%v", err)
		return
	}

	log.Printf("[api] stopLive: SUCCESS")
	writeJSON(w, http.StatusOK, map[string]string{"status": "stopped"})
}

type overlayStartReq struct {
	URL       string `json:"url"`        // SpeedHive URL (alternative to event_id/session_id)
	EventID   string `json:"event_id"`
	SessionID string `json:"session_id"` // optional — uses /active if empty
	MaxRows   int    `json:"max_rows"`
}

// parseSpeedHiveURL extracts event_id and session_id from a SpeedHive URL.
// Format: https://speedhive.mylaps.com/livetiming/{event_id}/sessions/{session_id}
func parseSpeedHiveURL(raw string) (eventID, sessionID string, err error) {
	u, err := url.Parse(raw)
	if err != nil {
		return "", "", fmt.Errorf("invalid URL: %w", err)
	}
	// Path: /livetiming/{event_id} or /livetiming/{event_id}/sessions/{session_id}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	if len(parts) < 2 || parts[0] != "livetiming" {
		return "", "", fmt.Errorf("expected /livetiming/{event_id}[/sessions/{session_id}]")
	}
	eventID = parts[1]
	if len(parts) >= 4 && parts[2] == "sessions" {
		sessionID = parts[3]
	}
	return eventID, sessionID, nil
}

func (h *Handler) startOverlay(w http.ResponseWriter, r *http.Request) {
	var req overlayStartReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		log.Printf("[api] startOverlay: bad JSON: %v", err)
		writeError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}

	log.Printf("[api] startOverlay: url=%q eventID=%s sessionID=%s maxRows=%d", req.URL, req.EventID, req.SessionID, req.MaxRows)

	// If URL provided, parse it to extract event_id and session_id
	if req.URL != "" {
		eid, sid, err := parseSpeedHiveURL(req.URL)
		if err != nil {
			log.Printf("[api] startOverlay: URL parse FAILED: %v", err)
			writeError(w, http.StatusBadRequest, "bad speedhive url: %v", err)
			return
		}
		log.Printf("[api] startOverlay: parsed URL → eventID=%s sessionID=%s", eid, sid)
		req.EventID = eid
		if sid != "" {
			req.SessionID = sid
		}
	}

	if req.EventID == "" {
		log.Printf("[api] startOverlay: no event_id")
		writeError(w, http.StatusBadRequest, "event_id or url required")
		return
	}

	// Stop existing overlay
	if h.overlay != nil {
		log.Printf("[api] startOverlay: stopping existing overlay")
		h.overlay.Stop()
		h.overlay = nil
	}

	// Ensure overlay dir exists
	if err := os.MkdirAll(h.cfg.OverlayDir, 0755); err != nil {
		log.Printf("[api] startOverlay: overlay dir FAILED: %v", err)
		writeError(w, http.StatusInternalServerError, "overlay dir: %v", err)
		return
	}

	pngPath := filepath.Join(h.cfg.OverlayDir, "timing.png")
	log.Printf("[api] startOverlay: pngPath=%s overlayDir=%s", pngPath, h.cfg.OverlayDir)

	h.overlay = overlay.New(overlay.Config{
		EventID:   req.EventID,
		SessionID: req.SessionID,
		PNGPath:   pngPath,
		MaxRows:   req.MaxRows,
	})
	h.overlay.Start()

	// Tell the switcher to use the overlay
	log.Printf("[api] startOverlay: calling SetOverlay(%s)", pngPath)
	h.sw.SetOverlay(pngPath)

	log.Printf("[api] startOverlay: SUCCESS event=%s session=%s png=%s", req.EventID, req.SessionID, pngPath)
	writeJSON(w, http.StatusOK, map[string]string{
		"status":   "started",
		"event_id": req.EventID,
		"png_path": pngPath,
	})
}

func (h *Handler) stopOverlay(w http.ResponseWriter, r *http.Request) {
	log.Printf("[api] stopOverlay called")
	if h.overlay == nil {
		log.Printf("[api] stopOverlay: no overlay running")
		writeError(w, http.StatusConflict, "no overlay running")
		return
	}
	h.overlay.Stop()
	h.overlay = nil
	log.Printf("[api] stopOverlay: calling SetOverlay(\"\")")
	h.sw.SetOverlay("")

	log.Printf("[api] stopOverlay: SUCCESS")
	writeJSON(w, http.StatusOK, map[string]string{"status": "stopped"})
}

func (h *Handler) overlayStatus(w http.ResponseWriter, r *http.Request) {
	if h.overlay == nil {
		log.Printf("[api] overlayStatus: inactive")
		writeJSON(w, http.StatusOK, map[string]any{"active": false})
		return
	}
	comps := h.overlay.Competitors()
	log.Printf("[api] overlayStatus: active, %d competitors", len(comps))
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
