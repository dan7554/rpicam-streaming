package config

import (
	"os"
	"strings"
)

type Config struct {
	Port           string   // HTTP server port
	MediaMTXAPI    string   // MediaMTX API URL (e.g. http://localhost:9997)
	MediaMTXRTSP   string   // MediaMTX RTSP URL (e.g. rtsp://localhost:8554)
	HLSAddress     string   // MediaMTX HLS address (e.g. :8888)
	WebRTCAddress  string   // MediaMTX WebRTC address (e.g. :8889)
	RTMPOutput     string   // Default RTMP output URL (e.g. rtmp://localhost:1935/live-output)
	BridgeAddr     string   // RTSP bridge proxy listen address (e.g. :8555)
	Cameras        []string // Camera path names (e.g. [cam1, cam2, cam3])
	OverlayDir     string   // Directory for overlay PNG files
}

func Load() *Config {
	camerasStr := getEnv("CAMERAS", "cam2,cam3")
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
		OverlayDir:    getEnv("OVERLAY_DIR", "/tmp/media-mtx-overlay"),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
