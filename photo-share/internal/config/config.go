package config

import (
	"os"
	"strings"
)

type Config struct {
	Port             string
	BaseURL          string
	GoogleClientID   string
	GoogleSecret     string
	SessionSecret    string
	S3Bucket         string
	S3Region         string
	AdminEmails      []string
	VenmoUsername     string
	DataDir          string
	ThumbnailMaxSize int
}

func Load() *Config {
	c := &Config{
		Port:             envOr("PORT", "8080"),
		BaseURL:          envOr("BASE_URL", "http://localhost:8080"),
		GoogleClientID:   os.Getenv("GOOGLE_CLIENT_ID"),
		GoogleSecret:     os.Getenv("GOOGLE_CLIENT_SECRET"),
		SessionSecret:    envOr("SESSION_SECRET", "change-me-in-production"),
		S3Bucket:         envOr("S3_BUCKET", "racetrack-photos"),
		S3Region:         envOr("S3_REGION", "us-west-2"),
		AdminEmails:      splitEmails(os.Getenv("ADMIN_EMAILS")),
		VenmoUsername:     envOr("VENMO_USERNAME", ""),
		DataDir:          envOr("DATA_DIR", "./data"),
		ThumbnailMaxSize: 600,
	}
	return c
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func splitEmails(s string) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, strings.ToLower(p))
		}
	}
	return out
}
