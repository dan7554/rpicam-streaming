package config

import (
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

type Config struct {
	Port          string   // HTTP server port
	MediaMTXAPI   string   // MediaMTX API URL (e.g. http://localhost:9997)
	MediaMTXRTSP  string   // MediaMTX RTSP URL (e.g. rtsp://localhost:8554)
	HLSAddress    string   // MediaMTX HLS address (e.g. :8888)
	WebRTCAddress string   // MediaMTX WebRTC address (e.g. :8889)
	RTMPOutput    string   // Default RTMP output URL (e.g. rtmp://localhost:1935/live-output)
	BridgeAddr    string   // RTSP bridge proxy listen address (e.g. :8555)
	Cameras       []string // Camera path names (e.g. [cam1, cam2, cam3])
	CameraUser    string   // SSH username for cameras
	CameraPass    string   // SSH password for cameras
	OverlayDir    string   // Directory for overlay PNG files
	AudioDevice   string   // macOS avfoundation audio device index (e.g. "0"), empty = disabled
}

// TailscaleDevice represents a device from tailscale status
type TailscaleDevice struct {
	Name   string
	IP     string
	Online bool
}

var (
	tailscaleCache     map[string]TailscaleDevice
	tailscaleCacheTime time.Time
	tailscaleMu        sync.Mutex
)

// GetCameraIP returns the Tailscale IP for a camera by querying tailscale status.
// Results are cached for 30 seconds. Returns empty string if camera is offline or not found.
func GetCameraIP(cameraName string) string {
	tailscaleMu.Lock()
	defer tailscaleMu.Unlock()

	// Check cache (10 second TTL)
	if time.Since(tailscaleCacheTime) < 10*time.Second && tailscaleCache != nil {
		if dev, ok := tailscaleCache[cameraName]; ok && dev.Online {
			return dev.IP
		}
	}

	// Refresh cache
	devices := queryTailscale()
	tailscaleCache = make(map[string]TailscaleDevice)
	for _, d := range devices {
		tailscaleCache[d.Name] = d
	}
	tailscaleCacheTime = time.Now()

	if dev, ok := tailscaleCache[cameraName]; ok && dev.Online {
		return dev.IP
	}
	return ""
}

// GetAllCameraIPs returns all cameras with their Tailscale IPs.
// Only returns cameras that are in the CAMERAS config and found online in Tailscale.
func GetAllCameraIPs(cameras []string) map[string]string {
	tailscaleMu.Lock()
	defer tailscaleMu.Unlock()

	// Refresh cache if needed (10 second TTL for responsive UI)
	if time.Since(tailscaleCacheTime) >= 10*time.Second || tailscaleCache == nil {
		devices := queryTailscale()
		tailscaleCache = make(map[string]TailscaleDevice)
		for _, d := range devices {
			tailscaleCache[d.Name] = d
		}
		tailscaleCacheTime = time.Now()
	}

	result := make(map[string]string)
	for _, cam := range cameras {
		// Look for exact match or hostname containing camera name (e.g. "rpicam1" matches "cam1")
		for name, dev := range tailscaleCache {
			if (name == cam || strings.Contains(strings.ToLower(name), strings.ToLower(cam))) && dev.Online {
				result[cam] = dev.IP
				break
			}
		}
	}
	return result
}

func queryTailscale() []TailscaleDevice {
	cmd := exec.Command("tailscale", "status", "--json")
	out, err := cmd.Output()
	if err != nil {
		return nil
	}

	var status struct {
		Peer map[string]struct {
			HostName     string   `json:"HostName"`
			TailscaleIPs []string `json:"TailscaleIPs"`
			Online       bool     `json:"Online"`
		} `json:"Peer"`
		Self struct {
			HostName     string   `json:"HostName"`
			TailscaleIPs []string `json:"TailscaleIPs"`
			Online       bool     `json:"Online"`
		} `json:"Self"`
	}
	if err := json.Unmarshal(out, &status); err != nil {
		return nil
	}

	var devices []TailscaleDevice
	// Add self (always online if we can run tailscale status)
	if len(status.Self.TailscaleIPs) > 0 {
		devices = append(devices, TailscaleDevice{
			Name:   status.Self.HostName,
			IP:     status.Self.TailscaleIPs[0],
			Online: true,
		})
	}
	// Add peers
	for _, peer := range status.Peer {
		if len(peer.TailscaleIPs) > 0 {
			devices = append(devices, TailscaleDevice{
				Name:   peer.HostName,
				IP:     peer.TailscaleIPs[0],
				Online: peer.Online,
			})
		}
	}
	return devices
}

func Load() *Config {
	camerasStr := getEnv("CAMERAS", "cam1,cam2,cam3")
	var cameras []string
	for _, c := range strings.Split(camerasStr, ",") {
		c = strings.TrimSpace(c)
		if c != "" {
			cameras = append(cameras, c)
		}
	}

	return &Config{
		Port:          getEnv("PORT", "8080"),
		MediaMTXAPI:   getEnv("MEDIAMTX_API", "http://localhost:9997"),
		MediaMTXRTSP:  getEnv("MEDIAMTX_RTSP", "rtsp://localhost:8554"),
		HLSAddress:    getEnv("MEDIAMTX_HLS", ":8888"),
		WebRTCAddress: getEnv("MEDIAMTX_WEBRTC", ":8889"),
		RTMPOutput:    getEnv("RTMP_OUTPUT", "rtmp://localhost:1935/live-output"),
		BridgeAddr:    getEnv("BRIDGE_ADDR", ":8555"),
		Cameras:       cameras,
		CameraUser:    getEnv("CAMERA_USER", "dan7554"),
		CameraPass:    getEnv("CAMERA_PASS", "!Dan1007554"),
		OverlayDir:    getEnv("OVERLAY_DIR", "/tmp/media-mtx-overlay"),
		AudioDevice:   getEnv("AUDIO_DEVICE", ""),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
