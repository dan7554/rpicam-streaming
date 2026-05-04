package api

import (
	"bufio"
	"encoding/json"
	"fmt"
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

	// Fleet management
	h.mux.HandleFunc("POST /api/fleet/heartbeat", h.fleetHeartbeat)
	h.mux.HandleFunc("GET /api/fleet/status", h.fleetStatus)

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
	Scale      int    `json:"scale"`       // render scale factor (default 1, use 2 for 1080p)
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
		Scale   int    `json:"scale"`
		Title   string `json:"title"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}
	log.Printf("[api] updateOverlay: format=%s maxRows=%d scale=%d title=%q", req.Format, req.MaxRows, req.Scale, req.Title)
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