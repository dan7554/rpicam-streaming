package api

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"image"
	_ "image/jpeg"
	"image/png"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"io"

	"github.com/dchristiani/media-mtx/internal/ads"
	"github.com/dchristiani/media-mtx/internal/config"
	"github.com/dchristiani/media-mtx/internal/overlay"
	"github.com/dchristiani/media-mtx/internal/switcher"
	"github.com/dchristiani/media-mtx/internal/uiconfig"
	xdraw "golang.org/x/image/draw"
)

type Handler struct {
	cfg          *config.Config
	sw           *switcher.Switcher
	mux          *http.ServeMux
	hlsProxy     *httputil.ReverseProxy
	webrtcProxy  *httputil.ReverseProxy
	overlay      *overlay.Overlay
	uiCfg        *uiconfig.Store
	fleet        *FleetStore
	adStore      *ads.Store
	buildVersion string
}

func (h *Handler) SetBuildVersion(v string) {
	h.buildVersion = v
}

func NewHandler(cfg *config.Config, sw *switcher.Switcher) *Handler {
	log.Printf("[api] NewHandler: port=%s hlsAddr=%s webrtcAddr=%s overlayDir=%s", cfg.Port, cfg.HLSAddress, cfg.WebRTCAddress, cfg.OverlayDir)
	h := &Handler{cfg: cfg, sw: sw, mux: http.NewServeMux(), fleet: NewFleetStore()}

	// Load persisted UI config
	configPath := filepath.Join(cfg.OverlayDir, "..", "ui-config.json")
	if cfg.OverlayDir == "" {
		configPath = "/tmp/ui-config.json"
	}
	h.uiCfg = uiconfig.NewStore(configPath)

	// Apply persisted logo settings to switcher
	uiCfgData := h.uiCfg.Get()
	tr, br := sw.LogoStatus()
	if uiCfgData.LogoTopRightOpacity != nil {
		tr.Opacity = *uiCfgData.LogoTopRightOpacity
	}
	if uiCfgData.LogoTopRightOffset != nil {
		tr.Offset = *uiCfgData.LogoTopRightOffset
	}
	if uiCfgData.LogoBotRightOpacity != nil {
		br.Opacity = *uiCfgData.LogoBotRightOpacity
	}
	if uiCfgData.LogoBotRightOffset != nil {
		br.Offset = *uiCfgData.LogoBotRightOffset
	}
	if uiCfgData.LogoTopRightScale != nil {
		tr.Scale = *uiCfgData.LogoTopRightScale
	}
	if uiCfgData.LogoBotRightScale != nil {
		br.Scale = *uiCfgData.LogoBotRightScale
	}
	sw.SetLogoConfig(tr, br)

	hlsURL, _ := url.Parse("http://localhost" + cfg.HLSAddress)
	h.hlsProxy = httputil.NewSingleHostReverseProxy(hlsURL)
	h.hlsProxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		w.WriteHeader(http.StatusBadGateway)
	}

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

	// Initialize ad store
	adDir := filepath.Join(filepath.Dir(cfg.OverlayDir), "ads")
	if adStore, err := ads.NewStore(adDir); err != nil {
		log.Printf("[api] WARNING: ads store init failed: %v", err)
	} else {
		h.adStore = adStore
	}

	h.routes()
	h.startMediaMTXWatchdog()
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
	h.mux.HandleFunc("POST /api/overlay/update", h.updateOverlay)
	h.mux.HandleFunc("GET /api/overlay/status", h.overlayStatus)
	h.mux.HandleFunc("POST /api/overlay/flag", h.overlayFlag)
	h.mux.HandleFunc("GET /api/audio/devices", h.getAudioDevices)
	h.mux.HandleFunc("GET /api/commentary/status", h.commentaryStatus)
	h.mux.HandleFunc("POST /api/commentary/update", h.commentaryUpdate)
	h.mux.HandleFunc("POST /api/commentary/slot", h.commentarySlot)
	h.mux.HandleFunc("POST /api/commentary/kick", h.commentaryKick)
	h.mux.HandleFunc("GET /api/config", h.getConfig)
	h.mux.HandleFunc("POST /api/config", h.postConfig)
	h.mux.HandleFunc("GET /api/version", h.getVersion)

	// Ads
	h.mux.HandleFunc("POST /api/ads/upload", h.adsUpload)
	h.mux.HandleFunc("GET /api/ads", h.adsList)
	h.mux.HandleFunc("DELETE /api/ads/{id}", h.adsDelete)
	h.mux.HandleFunc("POST /api/ads/play", h.adsPlay)
	h.mux.HandleFunc("POST /api/ads/stop", h.adsStop)
	h.mux.HandleFunc("GET /api/ads/playback", h.adsPlayback)
	h.mux.HandleFunc("GET /api/ads/preview/{id}", h.adsPreview)

	// Logos
	h.mux.HandleFunc("POST /api/logo/upload", h.logoUpload)
	h.mux.HandleFunc("DELETE /api/logo/{position}", h.logoDelete)
	h.mux.HandleFunc("GET /api/logo/status", h.logoStatus)
	h.mux.HandleFunc("POST /api/logo/settings", h.logoSettings)
	h.mux.HandleFunc("GET /api/logo/preview/{position}", h.logoPreview)

	// Fleet management
	h.mux.HandleFunc("POST /api/fleet/heartbeat", h.fleetHeartbeat)
	h.mux.HandleFunc("GET /api/fleet/status", h.fleetStatus)

	// Debug tools
	h.mux.HandleFunc("POST /api/debug/restart", h.debugRestart)
	h.mux.HandleFunc("GET /api/debug/logs", h.debugLogs)
	h.mux.HandleFunc("GET /api/debug/tailscale", h.debugTailscale)
	h.mux.HandleFunc("POST /api/debug/tailscale/up", h.debugTailscaleUp)
	h.mux.HandleFunc("POST /api/camera/control", h.cameraControl)
	h.mux.HandleFunc("GET /api/camera/list", h.cameraList)
	h.mux.HandleFunc("GET /api/camera/stream-config", h.getCameraStreamConfig)
	h.mux.HandleFunc("POST /api/camera/stream-config", h.postCameraStreamConfig)

	// Serve debug page at /debug
	h.mux.HandleFunc("GET /debug", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, "web/debug.html")
	})

	// Serve viewer page at /viewer
	h.mux.HandleFunc("GET /viewer", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, "web/viewer.html")
	})

	// Serve fleet page at /fleet
	h.mux.HandleFunc("GET /fleet", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, "web/fleet.html")
	})

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
	// WebRTC/WHEP reverse proxy — for low-latency previews
	if len(r.URL.Path) >= 8 && r.URL.Path[:8] == "/webrtc/" {
		r.URL.Path = r.URL.Path[7:] // strip /webrtc prefix, keep leading /
		h.webrtcProxy.ServeHTTP(w, r)
		return
	}
	h.mux.ServeHTTP(w, r)
}

// getStreams returns the configured camera list with ready status from MediaMTX.
func (h *Handler) getStreams(w http.ResponseWriter, r *http.Request) {
	// Query MediaMTX for path status
	readyPaths := map[string]bool{}
	resp, err := http.Get(h.cfg.MediaMTXAPI + "/v3/paths/list")
	if err == nil {
		defer resp.Body.Close()
		var data struct {
			Items []struct {
				Name  string `json:"name"`
				Ready bool   `json:"ready"`
			} `json:"items"`
		}
		if json.NewDecoder(resp.Body).Decode(&data) == nil {
			for _, item := range data.Items {
				readyPaths[item.Name] = item.Ready
			}
		}
	}

	// Return only configured cameras
	type streamItem struct {
		Name  string `json:"name"`
		Ready bool   `json:"ready"`
	}
	items := make([]streamItem, 0, len(h.cfg.Cameras))
	for _, cam := range h.cfg.Cameras {
		items = append(items, streamItem{Name: cam, Ready: readyPaths[cam]})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"itemCount": len(items),
		"items":     items,
	})
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
	switchStart := time.Now()
	if err := h.sw.Switch(req.Stream); err != nil {
		log.Printf("[api] switchStream: FAILED after %dms: %v", time.Since(switchStart).Milliseconds(), err)
		writeError(w, http.StatusConflict, "%v", err)
		return
	}

	log.Printf("[api] switchStream: SUCCESS → %s in %dms", req.Stream, time.Since(switchStart).Milliseconds())
	writeJSON(w, http.StatusOK, map[string]string{"status": "switched", "stream": req.Stream})
}

type liveStartReq struct {
	Stream     string `json:"stream"`
	YouTubeKey string `json:"youtube_key"`
	RTMPDest   string `json:"rtmp_dest"`
	Audio      bool   `json:"audio"`
}

func (h *Handler) startLive(w http.ResponseWriter, r *http.Request) {
	var req liveStartReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		log.Printf("[api] startLive: bad JSON: %v", err)
		writeError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}
	if req.Stream == "" {
		if len(h.cfg.Cameras) > 0 {
			req.Stream = h.cfg.Cameras[0]
		} else {
			req.Stream = "cam1"
		}
	}

	// Determine RTMP destination: youtube key, explicit URL, or local default
	rtmpDest := h.cfg.RTMPOutput // default: local MediaMTX
	if req.YouTubeKey != "" {
		rtmpDest = "rtmp://a.rtmp.youtube.com/live2/" + req.YouTubeKey
	} else if req.RTMPDest != "" {
		rtmpDest = req.RTMPDest
	}

	// Determine audio device: use configured device if audio requested
	audioDevice := ""
	if req.Audio && h.cfg.AudioDevice != "" {
		audioDevice = h.cfg.AudioDevice
	}

	log.Printf("[api] startLive: stream=%s rtmpDest=%s youtubeKey=%q audio=%v audioDevice=%q", req.Stream, rtmpDest, req.YouTubeKey, req.Audio, audioDevice)

	// Always use FFmpeg mode so the composited live-output is available
	if err := h.sw.StartLive(req.Stream, rtmpDest, false, audioDevice); err != nil {
		log.Printf("[api] startLive: FAILED: %v", err)
		writeError(w, http.StatusConflict, "%v", err)
		return
	}

	log.Printf("[api] startLive: SUCCESS stream=%s dest=%s", req.Stream, rtmpDest)

	// Persist UI config
	audioEnabled := req.Audio
	h.uiCfg.Merge(uiconfig.UIConfig{
		YouTubeKey:   req.YouTubeKey,
		AudioEnabled: &audioEnabled,
	})

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
	URL        string `json:"url"`         // SpeedHive URL (alternative to event_id/session_id)
	EventID    string `json:"event_id"`
	SessionID  string `json:"session_id"`  // optional — uses /active if empty
	Format     string `json:"format"`      // "full", "condensed", "minimal" (default "full")
	MaxRows    int    `json:"max_rows"`
	Scale      float64 `json:"scale"`       // render scale factor (default 1, use 2 for 1080p)
	Title      string `json:"title"`       // custom title override (replaces SpeedHive session name)
	FlagStatus string `json:"flag_status"` // flag status text, e.g. "Red Flag"
}

// parseSpeedHiveURL extracts event_id and session_id from a SpeedHive URL.
// Supported formats:
//
//	https://speedhive.mylaps.com/livetiming/{event_id}
//	https://speedhive.mylaps.com/livetiming/{event_id}/sessions/{session_id}
//	https://speedhive.mylaps.com/sessions/{session_id}
func parseSpeedHiveURL(raw string) (eventID, sessionID string, err error) {
	u, err := url.Parse(raw)
	if err != nil {
		return "", "", fmt.Errorf("invalid URL: %w", err)
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	// /sessions/{session_id} — session-only URL
	if len(parts) == 2 && parts[0] == "sessions" {
		return "", parts[1], nil
	}
	// /livetiming/{event_id}[/sessions/{session_id}]
	if len(parts) >= 2 && parts[0] == "livetiming" {
		eventID = parts[1]
		if len(parts) >= 4 && parts[2] == "sessions" {
			sessionID = parts[3]
		}
		return eventID, sessionID, nil
	}
	return "", "", fmt.Errorf("expected /livetiming/{event_id}[/sessions/{session_id}] or /sessions/{session_id}")
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

	if req.EventID == "" && req.SessionID == "" {
		log.Printf("[api] startOverlay: no event_id or session_id")
		writeError(w, http.StatusBadRequest, "event_id, session_id, or url required")
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
		EventID:    req.EventID,
		SessionID:  req.SessionID,
		PNGPath:    pngPath,
		Format:     req.Format,
		MaxRows:    req.MaxRows,
		Scale:      req.Scale,
		Title:      req.Title,
		FlagStatus: req.FlagStatus,
	})
	h.overlay.Start()

	// Register overlay as pauser so ads can suppress rendering
	h.sw.SetOverlayPauser(h.overlay)

	// Tell the switcher to use the overlay
	log.Printf("[api] startOverlay: calling SetOverlay(%s)", pngPath)
	h.sw.SetOverlay(pngPath)

	log.Printf("[api] startOverlay: SUCCESS event=%s session=%s png=%s", req.EventID, req.SessionID, pngPath)

	// Persist overlay config — save the original input URL if provided, otherwise event_id
	overlayInput := req.URL
	if overlayInput == "" {
		overlayInput = req.EventID
	}
	h.uiCfg.SetOverlay(overlayInput, req.Format, req.MaxRows, req.Scale)

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
	h.sw.SetOverlayPauser(nil)
	log.Printf("[api] stopOverlay: calling SetOverlay(\"\")")
	h.sw.SetOverlay("")

	log.Printf("[api] stopOverlay: SUCCESS")
	writeJSON(w, http.StatusOK, map[string]string{"status": "stopped"})
}

func (h *Handler) updateOverlay(w http.ResponseWriter, r *http.Request) {
	if h.overlay == nil {
		writeError(w, http.StatusConflict, "no overlay running")
		return
	}
	var req struct {
		Format  string `json:"format"`
		MaxRows int    `json:"max_rows"`
		Scale   float64 `json:"scale"`
		Title   string `json:"title"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}
	log.Printf("[api] updateOverlay: format=%s maxRows=%d scale=%.1f title=%q", req.Format, req.MaxRows, req.Scale, req.Title)
	h.overlay.Update(req.Format, req.MaxRows, req.Scale, req.Title)
	writeJSON(w, http.StatusOK, map[string]string{"status": "updated"})
}

func (h *Handler) overlayStatus(w http.ResponseWriter, r *http.Request) {
	if h.overlay == nil {
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

func (h *Handler) overlayFlag(w http.ResponseWriter, r *http.Request) {
	var req struct {
		FlagStatus string `json:"flag_status"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}
	if h.overlay == nil {
		writeError(w, http.StatusBadRequest, "no overlay active")
		return
	}
	h.overlay.SetFlagStatus(req.FlagStatus)
	log.Printf("[api] overlayFlag: set to %q", req.FlagStatus)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "flag_status": req.FlagStatus})
}

// --- Ads ---

func (h *Handler) adsUpload(w http.ResponseWriter, r *http.Request) {
	if h.adStore == nil {
		writeError(w, http.StatusInternalServerError, "ad store not initialized")
		return
	}

	// 500MB max
	r.ParseMultipartForm(500 << 20)
	file, header, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, "missing file: %v", err)
		return
	}
	defer file.Close()

	name := strings.TrimSuffix(header.Filename, filepath.Ext(header.Filename))

	// Save original
	origDir := filepath.Join(filepath.Dir(h.cfg.OverlayDir), "ads", "originals")
	os.MkdirAll(origDir, 0755)
	ext := filepath.Ext(header.Filename)
	if ext == "" {
		ext = ".mp4"
	}
	origPath := filepath.Join(origDir, fmt.Sprintf("%d%s", time.Now().UnixNano(), ext))
	dst, err := os.Create(origPath)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "save file: %v", err)
		return
	}
	if _, err := io.Copy(dst, file); err != nil {
		dst.Close()
		writeError(w, http.StatusInternalServerError, "write file: %v", err)
		return
	}
	dst.Close()

	ad := h.adStore.Add(name, origPath)
	log.Printf("[api] adsUpload: %s (%s) → transcoding", name, ad.ID)
	writeJSON(w, http.StatusOK, ad)
}

func (h *Handler) adsList(w http.ResponseWriter, r *http.Request) {
	if h.adStore == nil {
		writeJSON(w, http.StatusOK, []struct{}{})
		return
	}
	writeJSON(w, http.StatusOK, h.adStore.List())
}

func (h *Handler) adsDelete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if h.adStore == nil || !h.adStore.Delete(id) {
		writeError(w, http.StatusNotFound, "ad not found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

func (h *Handler) adsPlay(w http.ResponseWriter, r *http.Request) {
	var req struct {
		IDs []string `json:"ids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}
	if len(req.IDs) == 0 {
		writeError(w, http.StatusBadRequest, "no ad IDs provided")
		return
	}

	var files []string
	var names []string
	for _, id := range req.IDs {
		ad := h.adStore.Get(id)
		if ad == nil {
			writeError(w, http.StatusNotFound, "ad %s not found", id)
			return
		}
		if ad.Status != "ready" {
			writeError(w, http.StatusConflict, "ad %s not ready (status: %s)", id, ad.Status)
			return
		}
		files = append(files, ad.TransFile)
		names = append(names, ad.Name)
	}

	if err := h.sw.PlayAds(files, names); err != nil {
		writeError(w, http.StatusConflict, "play ads: %v", err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "playing"})
}

func (h *Handler) adsStop(w http.ResponseWriter, r *http.Request) {
	if err := h.sw.StopAds(); err != nil {
		writeError(w, http.StatusConflict, "stop ads: %v", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "stopped"})
}

func (h *Handler) adsPlayback(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, h.sw.AdStatus())
}

func (h *Handler) adsPreview(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	ad := h.adStore.Get(id)
	if ad == nil {
		writeError(w, http.StatusNotFound, "ad not found")
		return
	}
	// Serve original if not transcoded yet, otherwise transcoded
	path := ad.TransFile
	if path == "" {
		path = ad.OrigFile
	}
	http.ServeFile(w, r, path)
}

// --- Audio ---

type audioDevice struct {
	Index string `json:"index"`
	Name  string `json:"name"`
}

func (h *Handler) getAudioDevices(w http.ResponseWriter, r *http.Request) {
	cmd := exec.Command("ffmpeg", "-f", "avfoundation", "-list_devices", "true", "-i", "")
	out, _ := cmd.CombinedOutput() // ffmpeg exits non-zero for -list_devices

	var devices []audioDevice
	re := regexp.MustCompile(`\[AVFoundation.*\] \[(\d+)\] (.+)`)
	scanner := bufio.NewScanner(strings.NewReader(string(out)))
	inAudio := false
	for scanner.Scan() {
		line := scanner.Text()
		if strings.Contains(line, "AVFoundation audio devices") {
			inAudio = true
			continue
		}
		if inAudio {
			if m := re.FindStringSubmatch(line); m != nil {
				devices = append(devices, audioDevice{Index: m[1], Name: m[2]})
			}
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"devices":    devices,
		"configured": h.cfg.AudioDevice,
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

// --- Commentary API ---

func (h *Handler) commentaryStatus(w http.ResponseWriter, r *http.Request) {
	cc := h.sw.CommentaryStatus()

	type slotResp struct {
		Index  int     `json:"index"`
		Active bool    `json:"active"`
		Volume float64 `json:"volume"`
	}
	slots := make([]slotResp, len(cc.Slots))
	for i, s := range cc.Slots {
		slots[i] = slotResp{Index: i, Active: s.Active, Volume: s.Volume}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"enabled":       cc.Enabled,
		"camera_volume": cc.CameraVolume,
		"slots":         slots,
	})
}

func (h *Handler) commentaryUpdate(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Enabled      *bool    `json:"enabled"`
		CameraVolume *float64 `json:"camera_volume"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}

	cc := h.sw.CommentaryStatus()
	if req.Enabled != nil {
		cc.Enabled = *req.Enabled
	}
	if req.CameraVolume != nil {
		cc.CameraVolume = *req.CameraVolume
	}

	log.Printf("[api] commentaryUpdate: enabled=%v cameraVol=%.2f", cc.Enabled, cc.CameraVolume)
	h.sw.SetCommentary(cc)

	// Persist camera volume
	if req.CameraVolume != nil {
		vol := int(*req.CameraVolume * 100)
		h.uiCfg.SetCameraVolume(vol)
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "updated"})
}

func (h *Handler) commentarySlot(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Slot   int      `json:"slot"`
		Active *bool    `json:"active"`
		Volume *float64 `json:"volume"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}

	cc := h.sw.CommentaryStatus()
	if req.Slot < 0 || req.Slot >= len(cc.Slots) {
		writeError(w, http.StatusBadRequest, "invalid slot %d (have %d)", req.Slot, len(cc.Slots))
		return
	}

	active := cc.Slots[req.Slot].Active
	volume := cc.Slots[req.Slot].Volume
	if req.Active != nil {
		active = *req.Active
	}
	if req.Volume != nil {
		volume = *req.Volume
	}

	log.Printf("[api] commentarySlot[%d]: active=%v volume=%.2f", req.Slot, active, volume)
	if err := h.sw.SetCommentarySlot(req.Slot, active, volume); err != nil {
		writeError(w, http.StatusBadRequest, "%v", err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "updated"})
}

func (h *Handler) commentaryKick(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Slot int `json:"slot"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}
	cc := h.sw.CommentaryStatus()
	if req.Slot < 0 || req.Slot >= len(cc.Slots) {
		writeError(w, http.StatusBadRequest, "invalid slot %d", req.Slot)
		return
	}
	log.Printf("[api] commentaryKick[%d]", req.Slot)
	if err := h.sw.SetCommentarySlot(req.Slot, false, cc.Slots[req.Slot].Volume); err != nil {
		writeError(w, http.StatusInternalServerError, "%v", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "kicked"})
}

// --- UI Config API ---

func (h *Handler) getConfig(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, h.uiCfg.Get())
}

func (h *Handler) postConfig(w http.ResponseWriter, r *http.Request) {
	var patch uiconfig.UIConfig
	if err := json.NewDecoder(r.Body).Decode(&patch); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}
	h.uiCfg.Merge(patch)
	writeJSON(w, http.StatusOK, h.uiCfg.Get())
}

func (h *Handler) getVersion(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"build": h.buildVersion})
}

func (h *Handler) debugRestart(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Service string `json:"service"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}
	log.Printf("[api] debugRestart: service=%s", req.Service)

	switch req.Service {
	case "mediamtx":
		// Send response first — restarting mediamtx also restarts stream-server
		// (systemd Requires= dependency), so we'd lose the connection.
		writeJSON(w, http.StatusOK, map[string]string{"message": "mediamtx restarting"})
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		go func() {
			time.Sleep(100 * time.Millisecond)
			log.Printf("[api] debugRestart mediamtx: restarting via systemctl")
			if err := exec.Command("sudo", "systemctl", "restart", "mediamtx").Run(); err != nil {
				log.Printf("[api] debugRestart mediamtx FAILED: %v", err)
			} else {
				log.Printf("[api] debugRestart mediamtx SUCCESS")
			}
		}()
	case "server":
		writeJSON(w, http.StatusOK, map[string]string{"message": "server restarting"})
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		go func() {
			time.Sleep(100 * time.Millisecond)
			log.Printf("[api] debugRestart server: restarting via systemctl")
			exec.Command("sudo", "systemctl", "restart", "stream-server").Run()
		}()
	default:
		writeError(w, http.StatusBadRequest, "unknown service: %s", req.Service)
	}
}

func (h *Handler) debugLogs(w http.ResponseWriter, r *http.Request) {
	service := r.URL.Query().Get("service")
	var unit string
	switch service {
	case "server":
		unit = "stream-server"
	case "mediamtx":
		unit = "mediamtx"
	default:
		writeError(w, http.StatusBadRequest, "unknown service: %s", service)
		return
	}

	out, err := exec.Command("journalctl", "-u", unit, "--no-pager", "-n", "100", "--output", "short-iso").Output()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "journalctl: %v", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"logs": string(out)})
}

func (h *Handler) debugTailscale(w http.ResponseWriter, r *http.Request) {
	// Check if tailscale is installed
	_, err := exec.LookPath("tailscale")
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"installed": false,
			"status":    "not_installed",
			"message":   "Tailscale is not installed on this server",
		})
		return
	}

	// Get tailscale status
	out, err := exec.Command("tailscale", "status", "--json").Output()
	if err != nil {
		// Tailscale might need authentication
		statusOut, _ := exec.Command("tailscale", "status").CombinedOutput()
		statusStr := string(statusOut)
		
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"installed": true,
			"status":    "error",
			"message":   statusStr,
		})
		return
	}

	// Parse the JSON status
	var status struct {
		BackendState string `json:"BackendState"`
		Self         struct {
			HostName     string   `json:"HostName"`
			TailscaleIPs []string `json:"TailscaleIPs"`
		} `json:"Self"`
		Peer map[string]struct {
			HostName     string   `json:"HostName"`
			TailscaleIPs []string `json:"TailscaleIPs"`
			Online       bool     `json:"Online"`
		} `json:"Peer"`
	}
	
	if err := json.Unmarshal(out, &status); err != nil {
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"installed": true,
			"status":    "error",
			"message":   "Failed to parse tailscale status: " + err.Error(),
		})
		return
	}

	// Build peer list
	peers := make([]map[string]interface{}, 0)
	for _, peer := range status.Peer {
		ip := ""
		if len(peer.TailscaleIPs) > 0 {
			ip = peer.TailscaleIPs[0]
		}
		peers = append(peers, map[string]interface{}{
			"hostname": peer.HostName,
			"ip":       ip,
			"online":   peer.Online,
		})
	}

	selfIP := ""
	if len(status.Self.TailscaleIPs) > 0 {
		selfIP = status.Self.TailscaleIPs[0]
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"installed":    true,
		"status":       status.BackendState,
		"hostname":     status.Self.HostName,
		"ip":           selfIP,
		"peers":        peers,
		"peer_count":   len(peers),
	})
}

func (h *Handler) debugTailscaleUp(w http.ResponseWriter, r *http.Request) {
	// Run tailscale up with --ssh to get auth URL
	cmd := exec.Command("sudo", "tailscale", "up", "--ssh", "--timeout=5s")
	out, err := cmd.CombinedOutput()
	outStr := string(out)
	
	// Look for auth URL
	authURLRegex := regexp.MustCompile(`https://login\.tailscale\.com/[^\s]+`)
	if match := authURLRegex.FindString(outStr); match != "" {
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"status":   "auth_required",
			"auth_url": match,
			"message":  "Please visit the URL to authenticate",
		})
		return
	}

	if err != nil {
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"status":  "error",
			"message": outStr,
		})
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":  "connected",
		"message": "Tailscale connected successfully",
	})
}

// --- Camera Control API ---

func (h *Handler) cameraList(w http.ResponseWriter, r *http.Request) {
	// Query Tailscale for camera IPs
	cameraHosts := config.GetAllCameraIPs(h.cfg.Cameras)
	
	cameras := make([]map[string]string, 0)
	for _, name := range h.cfg.Cameras {
		ip := cameraHosts[name]
		if ip == "" {
			ip = "offline"
		}
		cameras = append(cameras, map[string]string{
			"name": name,
			"ip":   ip,
		})
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"cameras": cameras})
}

// getCameraStreamConfig reads /etc/rpicam-stream.conf from a camera via SSH.
func (h *Handler) getCameraStreamConfig(w http.ResponseWriter, r *http.Request) {
	camera := r.URL.Query().Get("camera")
	if camera == "" {
		writeError(w, http.StatusBadRequest, "camera parameter required")
		return
	}

	cameraHosts := config.GetAllCameraIPs(h.cfg.Cameras)
	ip := cameraHosts[camera]
	if ip == "" {
		writeError(w, http.StatusNotFound, "camera %s offline", camera)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "ssh", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no",
		fmt.Sprintf("%s@%s", h.cfg.CameraUser, ip), "cat /etc/rpicam-stream.conf")
	out, err := cmd.CombinedOutput()
	if err != nil {
		outStr := string(out)
		if strings.Contains(outStr, "login.tailscale.com") {
			authURLRegex := regexp.MustCompile(`https://login\.tailscale\.com/[^\s]+`)
			if match := authURLRegex.FindString(outStr); match != "" {
				writeJSON(w, http.StatusServiceUnavailable, map[string]string{
					"error":    "tailscale_auth_required",
					"auth_url": match,
					"message":  "Tailscale SSH session expired. Open the auth URL to re-authenticate.",
				})
				return
			}
		}
		writeError(w, http.StatusInternalServerError, "ssh failed: %v", err)
		return
	}

	// Parse key=value pairs
	cfgMap := make(map[string]string)
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 {
			cfgMap[strings.TrimSpace(parts[0])] = strings.TrimSpace(parts[1])
		}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"camera": camera,
		"config": cfgMap,
	})
}

// postCameraStreamConfig writes /etc/rpicam-stream.conf on a camera via SSH and restarts the stream.
func (h *Handler) postCameraStreamConfig(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Camera string            `json:"camera"`
		Config map[string]string `json:"config"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}
	if req.Camera == "" || len(req.Config) == 0 {
		writeError(w, http.StatusBadRequest, "camera and config required")
		return
	}

	// Validate allowed keys
	allowedKeys := map[string]bool{
		"WIDTH": true, "HEIGHT": true, "FPS": true,
		"BITRATE": true, "SPEED_PRESET": true, "PROTOCOL": true,
		"MEDIAMTX_HOST": true, "AUDIO_DEVICE": true,
	}
	for key := range req.Config {
		if !allowedKeys[key] {
			writeError(w, http.StatusBadRequest, "invalid config key: %s", key)
			return
		}
	}

	cameraHosts := config.GetAllCameraIPs(h.cfg.Cameras)
	ip := cameraHosts[req.Camera]
	if ip == "" {
		writeError(w, http.StatusNotFound, "camera %s offline", req.Camera)
		return
	}

	// Read existing config first so we can merge (preserve AUDIO_DEVICE etc.)
	readCtx, readCancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer readCancel()
	readCmd := exec.CommandContext(readCtx, "ssh", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no",
		fmt.Sprintf("%s@%s", h.cfg.CameraUser, ip), "cat /etc/rpicam-stream.conf")
	existingOut, _ := readCmd.CombinedOutput()

	// Parse existing config
	existing := make(map[string]string)
	existingScanner := bufio.NewScanner(bytes.NewReader(existingOut))
	for existingScanner.Scan() {
		line := strings.TrimSpace(existingScanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 {
			existing[strings.TrimSpace(parts[0])] = strings.TrimSpace(parts[1])
		}
	}

	// Merge: new values override existing
	for key, val := range req.Config {
		existing[key] = val
	}

	// Build merged config file content
	var confLines []string
	for key, val := range existing {
		confLines = append(confLines, fmt.Sprintf("%s=%s", key, val))
	}
	confContent := strings.Join(confLines, "\n") + "\n"

	// Write config and restart stream
	remoteCmd := fmt.Sprintf(
		"printf '%%s\\n' '%s' | sudo -S bash -c 'echo \"%s\" > /etc/rpicam-stream.conf && systemctl restart rpicam-stream && echo OK'",
		h.cfg.CameraPass,
		strings.ReplaceAll(confContent, "\"", "\\\""),
	)

	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "ssh", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=no",
		fmt.Sprintf("%s@%s", h.cfg.CameraUser, ip), remoteCmd)
	out, err := cmd.CombinedOutput()
	if err != nil {
		outStr := string(out)
		if strings.Contains(outStr, "login.tailscale.com") {
			authURLRegex := regexp.MustCompile(`https://login\.tailscale\.com/[^\s]+`)
			if match := authURLRegex.FindString(outStr); match != "" {
				writeJSON(w, http.StatusServiceUnavailable, map[string]string{
					"error":    "tailscale_auth_required",
					"auth_url": match,
					"message":  "Tailscale SSH session expired. Open the auth URL to re-authenticate.",
				})
				return
			}
		}
		writeError(w, http.StatusInternalServerError, "ssh failed: %v - %s", err, string(out))
		return
	}

	log.Printf("[api] cameraStreamConfig: updated %s config: %v", req.Camera, req.Config)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "camera": req.Camera})
}

func (h *Handler) cameraControl(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Camera string `json:"camera"` // cam1, cam3, or "all"
		Action string `json:"action"` // sleep, stream, reboot, restart
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}
	log.Printf("[api] cameraControl: camera=%s action=%s", req.Camera, req.Action)

	if h.cfg.CameraPass == "" {
		writeError(w, http.StatusInternalServerError, "CAMERA_PASS not configured")
		return
	}

	// Get current camera IPs from Tailscale
	cameraHosts := config.GetAllCameraIPs(h.cfg.Cameras)

	// Build list of cameras to control
	var targets []string
	if req.Camera == "all" {
		targets = h.cfg.Cameras
	} else {
		// Check if camera is in configured list
		found := false
		for _, c := range h.cfg.Cameras {
			if c == req.Camera {
				found = true
				break
			}
		}
		if !found {
			writeError(w, http.StatusBadRequest, "unknown camera: %s", req.Camera)
			return
		}
		targets = []string{req.Camera}
	}

	// Execute action on each camera
	results := make(map[string]string)
	for _, cam := range targets {
		ip := cameraHosts[cam]
		if ip == "" {
			results[cam] = "offline (not found in Tailscale)"
			continue
		}
		
		var remoteCmd string

		switch req.Action {
		case "sleep":
			remoteCmd = `
systemctl stop rpicam-stream 2>/dev/null || true
systemctl disable rpicam-stream 2>/dev/null || true
systemctl stop health-agent 2>/dev/null || true
systemctl disable health-agent 2>/dev/null || true
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo powersave > "$cpu" 2>/dev/null || true; done
MIN=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq 2>/dev/null || echo 600000)
echo $MIN > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null || true
echo 0 > /sys/devices/system/cpu/cpu1/online 2>/dev/null || true
echo 0 > /sys/devices/system/cpu/cpu2/online 2>/dev/null || true
echo 0 > /sys/devices/system/cpu/cpu3/online 2>/dev/null || true
echo none > /sys/class/leds/ACT/trigger 2>/dev/null || true
echo 0 > /sys/class/leds/ACT/brightness 2>/dev/null || true
echo "deep sleep active - 1 core @ min freq"
`
		case "stream":
			remoteCmd = `
echo 1 > /sys/devices/system/cpu/cpu1/online 2>/dev/null || true
echo 1 > /sys/devices/system/cpu/cpu2/online 2>/dev/null || true
echo 1 > /sys/devices/system/cpu/cpu3/online 2>/dev/null || true
echo 2400000 > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null || true
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo ondemand > "$cpu" 2>/dev/null || echo schedutil > "$cpu" 2>/dev/null || true; done
systemctl enable health-agent 2>/dev/null || true
systemctl start health-agent 2>/dev/null || true
systemctl enable rpicam-stream 2>/dev/null || true
systemctl start rpicam-stream
sleep 2
if systemctl is-active --quiet rpicam-stream; then echo "stream mode active"; else echo "stream failed to start"; fi
`
		case "reboot":
			remoteCmd = `reboot`
		case "reboot-cli":
			remoteCmd = `
systemctl set-default multi-user.target
echo "Default set to CLI, rebooting..."
reboot
`
		case "reboot-gui":
			remoteCmd = `
systemctl set-default graphical.target
echo "Default set to GUI, rebooting..."
reboot
`
		case "restart":
			remoteCmd = `systemctl restart rpicam-stream && echo "stream restarted"`
		default:
			results[cam] = "unknown action: " + req.Action
			continue
		}

		// Build SSH command with password via stdin
		sshCmd := fmt.Sprintf("printf '%%s\\n' '%s' | sudo -S bash -c '%s'",
			h.cfg.CameraPass, strings.ReplaceAll(remoteCmd, "'", "'\\''"))
		
		cmd := exec.Command("ssh", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=no",
			fmt.Sprintf("%s@%s", h.cfg.CameraUser, ip), sshCmd)
		
		out, err := cmd.CombinedOutput()
		outStr := string(out)
		
		// Check for Tailscale auth URL
		if strings.Contains(outStr, "login.tailscale.com") {
			// Extract the auth URL
			authURLRegex := regexp.MustCompile(`https://login\.tailscale\.com/[^\s]+`)
			if match := authURLRegex.FindString(outStr); match != "" {
				results[cam] = fmt.Sprintf("AUTH_REQUIRED:%s", match)
				continue
			}
		}
		
		if err != nil {
			results[cam] = fmt.Sprintf("error: %v - %s", err, outStr)
		} else {
			// Extract last line as status
			lines := strings.Split(strings.TrimSpace(outStr), "\n")
			results[cam] = lines[len(lines)-1]
		}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"results": results})
}

// --- Logo API ---

// renderScaledLogo reads the original PNG, scales it by the given factor,
// and writes the result to destPath. Scale of 1.0 copies as-is.
func renderScaledLogo(origPath, destPath string, scale float64) error {
	f, err := os.Open(origPath)
	if err != nil {
		return err
	}
	defer f.Close()

	srcImg, err := png.Decode(f)
	if err != nil {
		return err
	}

	bounds := srcImg.Bounds()
	newW := int(float64(bounds.Dx()) * scale)
	newH := int(float64(bounds.Dy()) * scale)
	if newW < 1 {
		newW = 1
	}
	if newH < 1 {
		newH = 1
	}

	var outImg image.Image
	if newW == bounds.Dx() && newH == bounds.Dy() {
		outImg = srcImg
	} else {
		dst := image.NewRGBA(image.Rect(0, 0, newW, newH))
		xdraw.BiLinear.Scale(dst, dst.Bounds(), srcImg, bounds, xdraw.Over, nil)
		outImg = dst
	}

	var buf bytes.Buffer
	if err := png.Encode(&buf, outImg); err != nil {
		return err
	}

	tmp := destPath + ".tmp"
	if err := os.WriteFile(tmp, buf.Bytes(), 0644); err != nil {
		return err
	}
	if err := os.Rename(tmp, destPath); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

func (h *Handler) logoUpload(w http.ResponseWriter, r *http.Request) {
	// 10MB max for logo images
	r.ParseMultipartForm(10 << 20)
	position := r.FormValue("position")
	if position != "top-right" && position != "bottom-right" {
		writeError(w, http.StatusBadRequest, "position must be 'top-right' or 'bottom-right'")
		return
	}

	file, _, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, "missing file: %v", err)
		return
	}
	defer file.Close()

	// Determine destination path
	overlayDir := h.sw.OverlayDir()
	var destPath, origPath string
	if position == "top-right" {
		destPath = filepath.Join(overlayDir, "logo-top-right.png")
		origPath = filepath.Join(overlayDir, "logo-top-right-orig.png")
	} else {
		destPath = filepath.Join(overlayDir, "logo-bot-right.png")
		origPath = filepath.Join(overlayDir, "logo-bot-right-orig.png")
	}

	// Read and decode image to validate it's a valid image
	imgData, err := io.ReadAll(file)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "read file: %v", err)
		return
	}

	// Decode, scale to max 300px, and re-encode as PNG
	srcImg, _, err := image.Decode(bytes.NewReader(imgData))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid image: %v", err)
		return
	}
	bounds := srcImg.Bounds()
	srcW, srcH := bounds.Dx(), bounds.Dy()
	const maxDim = 300
	if srcW > maxDim || srcH > maxDim {
		scale := float64(maxDim) / float64(srcW)
		if srcH > srcW {
			scale = float64(maxDim) / float64(srcH)
		}
		newW := int(float64(srcW) * scale)
		newH := int(float64(srcH) * scale)
		dst := image.NewRGBA(image.Rect(0, 0, newW, newH))
		xdraw.BiLinear.Scale(dst, dst.Bounds(), srcImg, bounds, xdraw.Over, nil)
		srcImg = dst
		log.Printf("[api] logoUpload: scaled %dx%d → %dx%d", srcW, srcH, newW, newH)
	}

	// Encode base image (max 300px) to PNG — this is the "original"
	var buf bytes.Buffer
	if err := png.Encode(&buf, srcImg); err != nil {
		writeError(w, http.StatusInternalServerError, "encode png: %v", err)
		return
	}

	// Write original atomically
	os.MkdirAll(overlayDir, 0755)
	tmp := origPath + ".tmp"
	if err := os.WriteFile(tmp, buf.Bytes(), 0644); err != nil {
		writeError(w, http.StatusInternalServerError, "write file: %v", err)
		return
	}
	if err := os.Rename(tmp, origPath); err != nil {
		os.Remove(tmp)
		writeError(w, http.StatusInternalServerError, "rename: %v", err)
		return
	}

	// Get current scale for this position
	cfg := h.uiCfg.Get()
	displayScale := 1.0
	if position == "top-right" && cfg.LogoTopRightScale != nil {
		displayScale = *cfg.LogoTopRightScale
	} else if position == "bottom-right" && cfg.LogoBotRightScale != nil {
		displayScale = *cfg.LogoBotRightScale
	}
	if displayScale <= 0 {
		displayScale = 1.0
	}

	// Render scaled display copy
	if err := renderScaledLogo(origPath, destPath, displayScale); err != nil {
		writeError(w, http.StatusInternalServerError, "render scaled: %v", err)
		return
	}

	// Enable the logo in config
	tr, br := h.sw.LogoStatus()

	if position == "top-right" {
		enabled := true
		cfg.LogoTopRightEnabled = &enabled
		tr.Path = destPath
		tr.Scale = displayScale
	} else {
		enabled := true
		cfg.LogoBotRightEnabled = &enabled
		br.Path = destPath
		br.Scale = displayScale
	}
	h.uiCfg.Merge(cfg)
	h.sw.SetLogoConfig(tr, br)

	log.Printf("[api] logoUpload: %s → %s", position, destPath)
	writeJSON(w, http.StatusOK, map[string]string{"status": "uploaded", "position": position})
}

func (h *Handler) logoDelete(w http.ResponseWriter, r *http.Request) {
	position := r.PathValue("position")
	if position != "top-right" && position != "bottom-right" {
		writeError(w, http.StatusBadRequest, "position must be 'top-right' or 'bottom-right'")
		return
	}

	overlayDir := h.sw.OverlayDir()
	var destPath string
	if position == "top-right" {
		destPath = filepath.Join(overlayDir, "logo-top-right.png")
		os.Remove(filepath.Join(overlayDir, "logo-top-right-orig.png"))
	} else {
		destPath = filepath.Join(overlayDir, "logo-bot-right.png")
		os.Remove(filepath.Join(overlayDir, "logo-bot-right-orig.png"))
	}

	// Write transparent PNG to disable (same pattern as overlay)
	img := image.NewRGBA(image.Rect(0, 0, 1, 1))
	tmp := destPath + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "create: %v", err)
		return
	}
	png.Encode(f, img)
	f.Close()
	os.Rename(tmp, destPath)

	// Disable in config
	cfg := h.uiCfg.Get()
	tr, br := h.sw.LogoStatus()

	if position == "top-right" {
		enabled := false
		cfg.LogoTopRightEnabled = &enabled
	} else {
		enabled := false
		cfg.LogoBotRightEnabled = &enabled
	}
	h.uiCfg.Merge(cfg)
	h.sw.SetLogoConfig(tr, br)

	log.Printf("[api] logoDelete: %s → transparent", position)
	writeJSON(w, http.StatusOK, map[string]string{"status": "removed", "position": position})
}

func (h *Handler) logoStatus(w http.ResponseWriter, r *http.Request) {
	cfg := h.uiCfg.Get()
	tr, br := h.sw.LogoStatus()

	// Check if real logos (not transparent 1x1) are present
	trHasLogo := false
	brHasLogo := false
	if fi, err := os.Stat(tr.Path); err == nil && fi.Size() > 100 {
		trHasLogo = true
	}
	if fi, err := os.Stat(br.Path); err == nil && fi.Size() > 100 {
		brHasLogo = true
	}

	trEnabled := cfg.LogoTopRightEnabled != nil && *cfg.LogoTopRightEnabled
	brEnabled := cfg.LogoBotRightEnabled != nil && *cfg.LogoBotRightEnabled

	trOpacity := 0.9
	if cfg.LogoTopRightOpacity != nil {
		trOpacity = *cfg.LogoTopRightOpacity
	}
	trOffset := 20
	if cfg.LogoTopRightOffset != nil {
		trOffset = *cfg.LogoTopRightOffset
	}

	brOpacity := 0.9
	if cfg.LogoBotRightOpacity != nil {
		brOpacity = *cfg.LogoBotRightOpacity
	}
	brOffset := 20
	if cfg.LogoBotRightOffset != nil {
		brOffset = *cfg.LogoBotRightOffset
	}

	trScale := 1.0
	if cfg.LogoTopRightScale != nil {
		trScale = *cfg.LogoTopRightScale
	}
	brScale := 1.0
	if cfg.LogoBotRightScale != nil {
		brScale = *cfg.LogoBotRightScale
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"top_right": map[string]any{
			"has_logo": trHasLogo,
			"enabled":  trEnabled,
			"opacity":  trOpacity,
			"offset":   trOffset,
			"scale":    trScale,
		},
		"bottom_right": map[string]any{
			"has_logo": brHasLogo,
			"enabled":  brEnabled,
			"opacity":  brOpacity,
			"offset":   brOffset,
			"scale":    brScale,
		},
	})
}

func (h *Handler) logoSettings(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Position string   `json:"position"` // "top-right" or "bottom-right"
		Opacity  *float64 `json:"opacity"`
		Offset   *int     `json:"offset"`
		Enabled  *bool    `json:"enabled"`
		Scale    *float64 `json:"scale"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}
	if req.Position != "top-right" && req.Position != "bottom-right" {
		writeError(w, http.StatusBadRequest, "position must be 'top-right' or 'bottom-right'")
		return
	}

	cfg := h.uiCfg.Get()
	tr, br := h.sw.LogoStatus()
	overlayDir := h.sw.OverlayDir()

	if req.Position == "top-right" {
		if req.Opacity != nil {
			cfg.LogoTopRightOpacity = req.Opacity
			tr.Opacity = *req.Opacity
		}
		if req.Offset != nil {
			cfg.LogoTopRightOffset = req.Offset
			tr.Offset = *req.Offset
		}
		if req.Enabled != nil {
			cfg.LogoTopRightEnabled = req.Enabled
		}
		if req.Scale != nil {
			cfg.LogoTopRightScale = req.Scale
			tr.Scale = *req.Scale
			origPath := filepath.Join(overlayDir, "logo-top-right-orig.png")
			destPath := filepath.Join(overlayDir, "logo-top-right.png")
			if _, err := os.Stat(origPath); err == nil {
				if err := renderScaledLogo(origPath, destPath, *req.Scale); err != nil {
					log.Printf("[api] logoSettings: render scaled TR failed: %v", err)
				}
			}
		}
	} else {
		if req.Opacity != nil {
			cfg.LogoBotRightOpacity = req.Opacity
			br.Opacity = *req.Opacity
		}
		if req.Offset != nil {
			cfg.LogoBotRightOffset = req.Offset
			br.Offset = *req.Offset
		}
		if req.Enabled != nil {
			cfg.LogoBotRightEnabled = req.Enabled
		}
		if req.Scale != nil {
			cfg.LogoBotRightScale = req.Scale
			br.Scale = *req.Scale
			origPath := filepath.Join(overlayDir, "logo-bot-right-orig.png")
			destPath := filepath.Join(overlayDir, "logo-bot-right.png")
			if _, err := os.Stat(origPath); err == nil {
				if err := renderScaledLogo(origPath, destPath, *req.Scale); err != nil {
					log.Printf("[api] logoSettings: render scaled BR failed: %v", err)
				}
			}
		}
	}

	h.uiCfg.Merge(cfg)
	h.sw.SetLogoConfig(tr, br)
	h.sw.RestartIfLive()

	log.Printf("[api] logoSettings: %s opacity=%v offset=%v enabled=%v scale=%v", req.Position, req.Opacity, req.Offset, req.Enabled, req.Scale)
	writeJSON(w, http.StatusOK, map[string]string{"status": "updated"})
}

func (h *Handler) logoPreview(w http.ResponseWriter, r *http.Request) {
	position := r.PathValue("position")
	if position != "top-right" && position != "bottom-right" {
		writeError(w, http.StatusBadRequest, "position must be 'top-right' or 'bottom-right'")
		return
	}

	overlayDir := h.sw.OverlayDir()
	var filename string
	if position == "top-right" {
		filename = "logo-top-right.png"
	} else {
		filename = "logo-bot-right.png"
	}

	path := filepath.Join(overlayDir, filename)
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-cache")
	http.ServeFile(w, r, path)
}