package ads

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Ad represents a single advertisement video.
type Ad struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	OrigFile    string    `json:"orig_file"`
	TransFile   string    `json:"trans_file"`
	Status      string    `json:"status"` // "pending", "transcoding", "ready", "error"
	Error       string    `json:"error,omitempty"`
	Duration    float64   `json:"duration"` // seconds
	UploadedAt  time.Time `json:"uploaded_at"`
	TranscodedAt time.Time `json:"transcoded_at,omitempty"`
}

// Store manages advertisement storage and transcoding.
type Store struct {
	mu       sync.RWMutex
	baseDir  string
	ads      []*Ad
	metaFile string
}

// NewStore creates an ad store at the given base directory.
func NewStore(baseDir string) (*Store, error) {
	origDir := filepath.Join(baseDir, "originals")
	transDir := filepath.Join(baseDir, "transcoded")
	for _, d := range []string{baseDir, origDir, transDir} {
		if err := os.MkdirAll(d, 0755); err != nil {
			return nil, fmt.Errorf("create dir %s: %w", d, err)
		}
	}
	s := &Store{
		baseDir:  baseDir,
		metaFile: filepath.Join(baseDir, "ads.json"),
	}
	s.load()

	// Start transcoding any pending ads
	go s.processQueue()

	return s, nil
}

func (s *Store) load() {
	data, err := os.ReadFile(s.metaFile)
	if err != nil {
		return
	}
	json.Unmarshal(data, &s.ads)
}

func (s *Store) save() {
	data, _ := json.MarshalIndent(s.ads, "", "  ")
	os.WriteFile(s.metaFile, data, 0644)
}

func genID() string {
	b := make([]byte, 8)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// Add registers a new ad from an uploaded file and queues transcoding.
func (s *Store) Add(name, origPath string) *Ad {
	ad := &Ad{
		ID:         genID(),
		Name:       name,
		OrigFile:   origPath,
		Status:     "pending",
		UploadedAt: time.Now(),
	}
	s.mu.Lock()
	s.ads = append(s.ads, ad)
	s.save()
	s.mu.Unlock()

	// Kick the transcoding queue
	go s.processQueue()

	return ad
}

// List returns all ads.
func (s *Store) List() []*Ad {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]*Ad, len(s.ads))
	copy(out, s.ads)
	return out
}

// Get returns an ad by ID.
func (s *Store) Get(id string) *Ad {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, a := range s.ads {
		if a.ID == id {
			return a
		}
	}
	return nil
}

// Delete removes an ad and its files.
func (s *Store) Delete(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i, a := range s.ads {
		if a.ID == id {
			os.Remove(a.OrigFile)
			if a.TransFile != "" {
				os.Remove(a.TransFile)
			}
			s.ads = append(s.ads[:i], s.ads[i+1:]...)
			s.save()
			return true
		}
	}
	return false
}

func (s *Store) processQueue() {
	s.mu.RLock()
	var pending *Ad
	for _, a := range s.ads {
		if a.Status == "pending" {
			pending = a
			break
		}
	}
	s.mu.RUnlock()

	if pending == nil {
		return
	}

	s.mu.Lock()
	pending.Status = "transcoding"
	s.save()
	s.mu.Unlock()

	log.Printf("[ads] transcoding %s (%s)...", pending.Name, pending.ID)

	transPath := filepath.Join(s.baseDir, "transcoded", pending.ID+".mp4")
	err := transcode(pending.OrigFile, transPath)

	s.mu.Lock()
	if err != nil {
		pending.Status = "error"
		pending.Error = err.Error()
		log.Printf("[ads] transcode FAILED %s: %v", pending.ID, err)
	} else {
		pending.Status = "ready"
		pending.TransFile = transPath
		pending.TranscodedAt = time.Now()
		pending.Duration = probeDuration(transPath)
		log.Printf("[ads] transcode OK %s (%.1fs)", pending.ID, pending.Duration)
	}
	s.save()
	s.mu.Unlock()

	// Process next in queue
	go s.processQueue()
}

// transcode converts a video to H264 1080p30 + AAC 128k.
func transcode(src, dst string) error {
	cmd := exec.Command("ffmpeg", "-y",
		"-i", src,
		"-c:v", "libx264",
		"-preset", "medium",
		"-b:v", "5000k",
		"-maxrate", "6000k",
		"-bufsize", "10000k",
		"-vf", "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=30",
		"-c:a", "aac",
		"-b:a", "128k",
		"-ar", "48000",
		"-ac", "2",
		"-movflags", "+faststart",
		dst,
	)
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// probeDuration uses ffprobe to get video duration in seconds.
func probeDuration(path string) float64 {
	cmd := exec.Command("ffprobe",
		"-v", "quiet",
		"-show_entries", "format=duration",
		"-of", "default=noprint_wrappers=1:nokey=1",
		path,
	)
	out, err := cmd.Output()
	if err != nil {
		return 0
	}
	d, _ := strconv.ParseFloat(strings.TrimSpace(string(out)), 64)
	return d
}
