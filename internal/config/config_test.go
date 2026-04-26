package config

import (
	"os"
	"testing"
)

func TestLoadDefaults(t *testing.T) {
	// Unset env vars to test defaults
	os.Unsetenv("PORT")
	os.Unsetenv("MEDIAMTX_API")
	os.Unsetenv("MEDIAMTX_RTSP")
	os.Unsetenv("BRIDGE_ADDR")
	os.Unsetenv("CAMERAS")

	cfg := Load()

	if cfg.Port != "8080" {
		t.Errorf("expected port=8080, got %q", cfg.Port)
	}
	if cfg.MediaMTXAPI != "http://localhost:9997" {
		t.Errorf("expected MediaMTXAPI=http://localhost:9997, got %q", cfg.MediaMTXAPI)
	}
	if cfg.MediaMTXRTSP != "rtsp://localhost:8554" {
		t.Errorf("expected MediaMTXRTSP=rtsp://localhost:8554, got %q", cfg.MediaMTXRTSP)
	}
	if cfg.HLSAddress != ":8888" {
		t.Errorf("expected HLSAddress=:8888, got %q", cfg.HLSAddress)
	}
	if cfg.RTMPOutput != "rtmp://localhost:1935/live-output" {
		t.Errorf("expected RTMPOutput=rtmp://localhost:1935/live-output, got %q", cfg.RTMPOutput)
	}
	if cfg.BridgeAddr != ":8555" {
		t.Errorf("expected BridgeAddr=:8555, got %q", cfg.BridgeAddr)
	}
	if len(cfg.Cameras) != 3 || cfg.Cameras[0] != "cam1" || cfg.Cameras[1] != "cam2" || cfg.Cameras[2] != "cam3" {
		t.Errorf("expected Cameras=[cam1,cam2,cam3], got %v", cfg.Cameras)
	}
}

func TestLoadFromEnv(t *testing.T) {
	t.Setenv("PORT", "9090")
	t.Setenv("MEDIAMTX_API", "http://custom:9997")
	t.Setenv("MEDIAMTX_RTSP", "rtsp://custom:8554")

	cfg := Load()

	if cfg.Port != "9090" {
		t.Errorf("expected port=9090, got %q", cfg.Port)
	}
	if cfg.MediaMTXAPI != "http://custom:9997" {
		t.Errorf("expected MediaMTXAPI=http://custom:9997, got %q", cfg.MediaMTXAPI)
	}
	if cfg.MediaMTXRTSP != "rtsp://custom:8554" {
		t.Errorf("expected MediaMTXRTSP=rtsp://custom:8554, got %q", cfg.MediaMTXRTSP)
	}
}

func TestGetEnvFallback(t *testing.T) {
	os.Unsetenv("NONEXISTENT_VAR")
	v := getEnv("NONEXISTENT_VAR", "fallback_value")
	if v != "fallback_value" {
		t.Errorf("expected fallback_value, got %q", v)
	}
}

func TestGetEnvSet(t *testing.T) {
	t.Setenv("TEST_VAR", "custom_value")
	v := getEnv("TEST_VAR", "fallback")
	if v != "custom_value" {
		t.Errorf("expected custom_value, got %q", v)
	}
}
