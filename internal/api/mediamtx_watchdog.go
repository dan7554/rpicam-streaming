package api

import (
	"encoding/json"
	"log"
	"net/http"
	"os/exec"
	"time"
)

// mediamtxWatchdog monitors MediaMTX WebRTC sessions and restarts MediaMTX
// if it detects sessions that are connected but not sending any RTP packets
// (a known bug after publisher reconnects).
func (h *Handler) startMediaMTXWatchdog() {
	go func() {
		ticker := time.NewTicker(15 * time.Second)
		defer ticker.Stop()

		var lastRestartTime time.Time

		for range ticker.C {
			// Don't restart more than once per 2 minutes
			if time.Since(lastRestartTime) < 2*time.Minute {
				continue
			}

			stuck := h.detectStuckWebRTC()
			if stuck {
				log.Printf("[watchdog] Detected stuck WebRTC sessions (0 RTP packets with active publisher). Restarting MediaMTX...")
				if err := exec.Command("sudo", "systemctl", "restart", "mediamtx").Run(); err != nil {
					log.Printf("[watchdog] Failed to restart MediaMTX: %v", err)
				} else {
					log.Printf("[watchdog] MediaMTX restarted successfully")
					lastRestartTime = time.Now()
				}
			}
		}
	}()
	log.Printf("[watchdog] MediaMTX WebRTC watchdog started (check every 15s)")
}

type mediamtxPath struct {
	Name         string `json:"name"`
	Ready        bool   `json:"ready"`
	InboundBytes int64  `json:"inboundBytes"`
}

type mediamtxWebRTCSession struct {
	ID             string    `json:"id"`
	Path           string    `json:"path"`
	State          string    `json:"state"`
	Created        time.Time `json:"created"`
	RTPPacketsSent int64     `json:"rtpPacketsSent"`
	BytesSent      int64     `json:"bytesSent"`
}

func (h *Handler) detectStuckWebRTC() bool {
	apiBase := h.cfg.MediaMTXAPI

	// Get paths with active publishers
	pathsResp, err := http.Get(apiBase + "/v3/paths/list")
	if err != nil {
		return false
	}
	defer pathsResp.Body.Close()

	var pathsData struct {
		Items []mediamtxPath `json:"items"`
	}
	if err := json.NewDecoder(pathsResp.Body).Decode(&pathsData); err != nil {
		return false
	}

	activePaths := map[string]bool{}
	for _, p := range pathsData.Items {
		if p.Ready && p.InboundBytes > 0 {
			activePaths[p.Name] = true
		}
	}

	if len(activePaths) == 0 {
		return false
	}

	// Get WebRTC sessions
	sessResp, err := http.Get(apiBase + "/v3/webrtcsessions/list")
	if err != nil {
		return false
	}
	defer sessResp.Body.Close()

	var sessData struct {
		Items []mediamtxWebRTCSession `json:"items"`
	}
	if err := json.NewDecoder(sessResp.Body).Decode(&sessData); err != nil {
		return false
	}

	// Check for sessions on active paths that have been connected >20s
	// but have sent 0 RTP packets
	now := time.Now()
	for _, s := range sessData.Items {
		if !activePaths[s.Path] {
			continue
		}
		if s.State != "read" {
			continue
		}
		age := now.Sub(s.Created)
		if age > 20*time.Second && s.RTPPacketsSent == 0 {
			log.Printf("[watchdog] Session %s on path %s: age=%s rtpSent=%d — STUCK",
				s.ID[:8], s.Path, age.Round(time.Second), s.RTPPacketsSent)
			return true
		}
	}

	return false
}
