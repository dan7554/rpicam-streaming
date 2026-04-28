package uiconfig

import (
	"encoding/json"
	"log"
	"os"
	"sync"
)

// UIConfig holds the server-side UI state that should persist across
// page reloads and be shared between multiple browser sessions.
type UIConfig struct {
	YouTubeKey    string  `json:"youtube_key,omitempty"`
	AudioEnabled  *bool   `json:"audio_enabled,omitempty"`
	OverlayURL    string  `json:"overlay_url,omitempty"`
	OverlayFormat string  `json:"overlay_format,omitempty"`
	OverlayRows   int     `json:"overlay_max_rows,omitempty"`
	OverlayScale  int     `json:"overlay_scale,omitempty"`
	CameraVolume  *int    `json:"camera_volume,omitempty"` // 0-100
}

// Store manages UIConfig persistence to a JSON file.
type Store struct {
	mu   sync.RWMutex
	path string
	cfg  UIConfig
}

// NewStore loads (or creates) the config file at path.
func NewStore(path string) *Store {
	s := &Store{path: path}
	data, err := os.ReadFile(path)
	if err == nil {
		if err := json.Unmarshal(data, &s.cfg); err != nil {
			log.Printf("[uiconfig] failed to parse %s: %v", path, err)
		}
	}
	return s
}

// Get returns a copy of the current config.
func (s *Store) Get() UIConfig {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.cfg
}

// Merge applies non-zero fields from patch onto the current config and saves.
func (s *Store) Merge(patch UIConfig) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if patch.YouTubeKey != "" {
		s.cfg.YouTubeKey = patch.YouTubeKey
	}
	if patch.AudioEnabled != nil {
		s.cfg.AudioEnabled = patch.AudioEnabled
	}
	if patch.OverlayURL != "" {
		s.cfg.OverlayURL = patch.OverlayURL
	}
	if patch.OverlayFormat != "" {
		s.cfg.OverlayFormat = patch.OverlayFormat
	}
	if patch.OverlayRows > 0 {
		s.cfg.OverlayRows = patch.OverlayRows
	}
	if patch.OverlayScale > 0 {
		s.cfg.OverlayScale = patch.OverlayScale
	}
	if patch.CameraVolume != nil {
		s.cfg.CameraVolume = patch.CameraVolume
	}

	s.save()
}

// SetYouTubeKey is a convenience for saving just the stream key.
func (s *Store) SetYouTubeKey(key string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cfg.YouTubeKey = key
	s.save()
}

// SetOverlay saves overlay parameters.
func (s *Store) SetOverlay(url, format string, rows, scale int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cfg.OverlayURL = url
	s.cfg.OverlayFormat = format
	s.cfg.OverlayRows = rows
	s.cfg.OverlayScale = scale
	s.save()
}

// SetCameraVolume saves the camera volume (0-100).
func (s *Store) SetCameraVolume(vol int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cfg.CameraVolume = &vol
	s.save()
}

func (s *Store) save() {
	data, err := json.MarshalIndent(s.cfg, "", "  ")
	if err != nil {
		log.Printf("[uiconfig] marshal error: %v", err)
		return
	}
	if err := os.WriteFile(s.path, data, 0644); err != nil {
		log.Printf("[uiconfig] write error: %v", err)
	}
}
