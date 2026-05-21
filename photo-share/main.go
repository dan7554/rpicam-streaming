package main

import (
	"embed"
	"io/fs"
	"log"
	"net/http"
	"time"

	"photo-share/internal/auth"
	"photo-share/internal/config"
	"photo-share/internal/db"
	"photo-share/internal/handlers"
	"photo-share/internal/storage"
)

//go:embed web
var webFS embed.FS

func main() {
	cfg := config.Load()

	store, err := db.New(cfg.DataDir, cfg.AdminEmails)
	if err != nil {
		log.Fatalf("database: %v", err)
	}
	defer store.Close()

	s3, err := storage.NewS3(cfg.S3Region, cfg.S3Bucket)
	if err != nil {
		log.Fatalf("s3: %v", err)
	}

	a := auth.New(cfg, store)
	h := handlers.New(cfg, store, s3)

	mux := http.NewServeMux()

	// Auth routes
	mux.HandleFunc("GET /auth/login", a.LoginHandler)
	mux.HandleFunc("GET /auth/callback", a.CallbackHandler)
	mux.HandleFunc("GET /auth/logout", a.LogoutHandler)
	mux.HandleFunc("GET /api/me", a.MeHandler)

	// Public API
	mux.HandleFunc("GET /api/folders", h.ListFolders)
	mux.HandleFunc("GET /api/folders/{slug}", h.GetFolder)
	mux.HandleFunc("GET /api/folders/{id}/photos", h.ListPhotos)
	mux.HandleFunc("GET /api/venmo/qr", h.VenmoQR)
	mux.HandleFunc("GET /api/venmo", h.VenmoInfo)

	// Authenticated user API
	mux.HandleFunc("POST /api/photos/{id}/favorite", h.ToggleFavorite)
	mux.HandleFunc("GET /api/favorites", h.ListFavorites)

	// Admin API
	mux.HandleFunc("POST /api/folders", auth.RequireAdmin(h.CreateFolder))
	mux.HandleFunc("PUT /api/folders/{id}", auth.RequireAdmin(h.RenameFolder))
	mux.HandleFunc("DELETE /api/folders/{id}", auth.RequireAdmin(h.DeleteFolder))
	mux.HandleFunc("POST /api/folders/{id}/photos", auth.RequireAdmin(h.UploadPhotos))
	mux.HandleFunc("POST /api/folders/{id}/cover", auth.RequireAdmin(h.SetFolderCover))
	mux.HandleFunc("DELETE /api/photos/{id}", auth.RequireAdmin(h.DeletePhoto))
	mux.HandleFunc("GET /api/users", auth.RequireAdmin(h.ListUsers))
	mux.HandleFunc("PUT /api/users/{id}/admin", auth.RequireAdmin(h.SetUserAdmin))

	// Static files
	webContent, err := fs.Sub(webFS, "web")
	if err != nil {
		log.Fatalf("web fs: %v", err)
	}
	fileServer := http.FileServer(http.FS(webContent))
	mux.Handle("GET /", fileServer)

	// Wrap with session middleware
	handler := a.SessionMiddleware(mux)

	// Clean expired sessions periodically
	go func() {
		for {
			time.Sleep(1 * time.Hour)
			store.CleanExpiredSessions()
		}
	}()

	log.Printf("Photo Share starting on :%s", cfg.Port)
	log.Printf("  Base URL: %s", cfg.BaseURL)
	log.Printf("  S3 Bucket: %s", cfg.S3Bucket)
	log.Printf("  Admin emails: %v", cfg.AdminEmails)
	if cfg.VenmoUsername != "" {
		log.Printf("  Venmo: @%s", cfg.VenmoUsername)
	}

	if err := http.ListenAndServe(":"+cfg.Port, handler); err != nil {
		log.Fatalf("server: %v", err)
	}
}
