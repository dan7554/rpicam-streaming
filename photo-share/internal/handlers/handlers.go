package handlers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"log"
	"net/http"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"photo-share/internal/auth"
	"photo-share/internal/config"
	"photo-share/internal/db"
	"photo-share/internal/storage"

	"github.com/disintegration/imaging"
	qrcode "github.com/skip2/go-qrcode"
)

type Handlers struct {
	store  *db.Store
	s3     *storage.S3
	config *config.Config
}

func New(cfg *config.Config, store *db.Store, s3 *storage.S3) *Handlers {
	return &Handlers{store: store, s3: s3, config: cfg}
}

var slugRegexp = regexp.MustCompile(`[^a-z0-9]+`)

func slugify(name string) string {
	s := strings.ToLower(name)
	s = slugRegexp.ReplaceAllString(s, "-")
	s = strings.Trim(s, "-")
	if s == "" {
		s = "untitled"
	}
	return s
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// ListFolders returns all top-level folders or subfolders.
func (h *Handlers) ListFolders(w http.ResponseWriter, r *http.Request) {
	var parentID *int64
	if pid := r.URL.Query().Get("parent_id"); pid != "" {
		id, err := strconv.ParseInt(pid, 10, 64)
		if err == nil {
			parentID = &id
		}
	}

	folders, err := h.store.ListFolders(parentID)
	if err != nil {
		writeError(w, 500, "failed to list folders")
		return
	}
	if folders == nil {
		folders = []db.Folder{}
	}

	// Generate presigned URLs for covers
	type folderResponse struct {
		db.Folder
		CoverURL string `json:"cover_url"`
	}
	resp := make([]folderResponse, len(folders))
	for i, f := range folders {
		resp[i] = folderResponse{Folder: f}
		if f.CoverKey != "" {
			url, err := h.s3.PresignedURL(r.Context(), f.CoverKey, 1*time.Hour)
			if err == nil {
				resp[i].CoverURL = url
			}
		}
	}

	writeJSON(w, 200, resp)
}

// CreateFolder creates a new gallery folder.
func (h *Handlers) CreateFolder(w http.ResponseWriter, r *http.Request) {
	user := auth.GetUser(r)

	var req struct {
		Name     string `json:"name"`
		ParentID *int64 `json:"parent_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, 400, "invalid request")
		return
	}
	if req.Name == "" {
		writeError(w, 400, "name is required")
		return
	}

	slug := slugify(req.Name)

	// Ensure unique slug
	if _, err := h.store.GetFolderBySlug(slug); err == nil {
		slug = fmt.Sprintf("%s-%d", slug, time.Now().Unix())
	}

	folder, err := h.store.CreateFolder(req.Name, slug, req.ParentID, user.ID)
	if err != nil {
		log.Printf("create folder error: %v", err)
		writeError(w, 500, "failed to create folder")
		return
	}

	writeJSON(w, 201, folder)
}

// RenameFolder renames a folder.
func (h *Handlers) RenameFolder(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "invalid folder id")
		return
	}

	var req struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Name == "" {
		writeError(w, 400, "name is required")
		return
	}

	slug := slugify(req.Name)
	if existing, err := h.store.GetFolderBySlug(slug); err == nil && existing.ID != id {
		slug = fmt.Sprintf("%s-%d", slug, time.Now().Unix())
	}

	if err := h.store.RenameFolder(id, req.Name, slug); err != nil {
		writeError(w, 500, "failed to rename folder")
		return
	}

	folder, _ := h.store.GetFolder(id)
	writeJSON(w, 200, folder)
}

// DeleteFolder deletes a folder and all its photos from S3.
func (h *Handlers) DeleteFolder(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "invalid folder id")
		return
	}

	originals, thumbnails, err := h.store.GetFolderPhotoKeys(id)
	if err != nil {
		writeError(w, 500, "failed to get photo keys")
		return
	}

	// Also get S3 keys from subfolders
	subfolders, _ := h.store.ListFolders(&id)
	for _, sub := range subfolders {
		so, st, err := h.store.GetFolderPhotoKeys(sub.ID)
		if err == nil {
			originals = append(originals, so...)
			thumbnails = append(thumbnails, st...)
		}
	}

	// Delete from S3
	allKeys := append(originals, thumbnails...)
	if err := h.s3.DeleteMultiple(r.Context(), allKeys); err != nil {
		log.Printf("s3 delete error: %v", err)
	}

	if err := h.store.DeleteFolder(id); err != nil {
		writeError(w, 500, "failed to delete folder")
		return
	}

	writeJSON(w, 200, map[string]string{"status": "deleted"})
}

// GetFolder returns a single folder by slug.
func (h *Handlers) GetFolder(w http.ResponseWriter, r *http.Request) {
	slug := r.PathValue("slug")
	folder, err := h.store.GetFolderBySlug(slug)
	if err != nil {
		writeError(w, 404, "folder not found")
		return
	}

	type parentInfo struct {
		ID   int64  `json:"id"`
		Name string `json:"name"`
		Slug string `json:"slug"`
	}
	type folderResponse struct {
		*db.Folder
		CoverURL string      `json:"cover_url"`
		Parent   *parentInfo `json:"parent,omitempty"`
	}
	resp := folderResponse{Folder: folder}
	if folder.CoverKey != "" {
		url, err := h.s3.PresignedURL(r.Context(), folder.CoverKey, 1*time.Hour)
		if err == nil {
			resp.CoverURL = url
		}
	}
	if folder.ParentID != nil {
		parent, err := h.store.GetFolder(*folder.ParentID)
		if err == nil {
			resp.Parent = &parentInfo{ID: parent.ID, Name: parent.Name, Slug: parent.Slug}
		}
	}

	writeJSON(w, 200, resp)
}

// ListPhotos returns all photos in a folder.
func (h *Handlers) ListPhotos(w http.ResponseWriter, r *http.Request) {
	folderID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "invalid folder id")
		return
	}

	photos, err := h.store.ListPhotos(folderID)
	if err != nil {
		writeError(w, 500, "failed to list photos")
		return
	}
	if photos == nil {
		photos = []db.Photo{}
	}

	// Get user's favorites if logged in
	var faves map[int64]bool
	if user := auth.GetUser(r); user != nil {
		faves, _ = h.store.GetUserFavoriteIDs(user.ID)
	}

	type photoResponse struct {
		db.Photo
		ThumbnailURL string `json:"thumbnail_url"`
		OriginalURL  string `json:"original_url"`
		Favorited    bool   `json:"favorited"`
	}
	resp := make([]photoResponse, len(photos))
	for i, p := range photos {
		resp[i] = photoResponse{Photo: p, Favorited: faves[p.ID]}
		if url, err := h.s3.PresignedURL(r.Context(), p.ThumbnailKey, 1*time.Hour); err == nil {
			resp[i].ThumbnailURL = url
		}
		if url, err := h.s3.PresignedURL(r.Context(), p.OriginalKey, 1*time.Hour); err == nil {
			resp[i].OriginalURL = url
		}
	}

	writeJSON(w, 200, resp)
}

// UploadPhotos handles multipart photo uploads.
func (h *Handlers) UploadPhotos(w http.ResponseWriter, r *http.Request) {
	user := auth.GetUser(r)
	folderID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "invalid folder id")
		return
	}

	folder, err := h.store.GetFolder(folderID)
	if err != nil {
		writeError(w, 404, "folder not found")
		return
	}

	// 100MB max
	if err := r.ParseMultipartForm(100 << 20); err != nil {
		writeError(w, 400, "request too large")
		return
	}

	files := r.MultipartForm.File["photos"]
	if len(files) == 0 {
		writeError(w, 400, "no photos uploaded")
		return
	}

	var uploaded []db.Photo
	for _, fh := range files {
		file, err := fh.Open()
		if err != nil {
			continue
		}

		data, err := io.ReadAll(file)
		file.Close()
		if err != nil {
			continue
		}

		contentType := fh.Header.Get("Content-Type")
		if !isImageType(contentType) {
			contentType = http.DetectContentType(data)
			if !isImageType(contentType) {
				continue
			}
		}

		// Decode to get dimensions
		imgReader := bytes.NewReader(data)
		imgConfig, _, err := image.DecodeConfig(imgReader)
		width, height := 0, 0
		if err == nil {
			width = imgConfig.Width
			height = imgConfig.Height
		}

		// Generate thumbnail
		thumbData, err := generateThumbnail(data, h.config.ThumbnailMaxSize)
		if err != nil {
			log.Printf("thumbnail error for %s: %v", fh.Filename, err)
			continue
		}

		// S3 keys
		ts := time.Now().UnixMilli()
		safeFilename := filepath.Base(fh.Filename)
		originalKey := fmt.Sprintf("photos/%s/%d/%s", folder.Slug, ts, safeFilename)
		thumbKey := fmt.Sprintf("thumbs/%s/%d/%s", folder.Slug, ts, safeFilename)

		// Upload to S3
		if err := h.s3.Upload(r.Context(), originalKey, data, contentType); err != nil {
			log.Printf("s3 upload original error: %v", err)
			continue
		}
		if err := h.s3.Upload(r.Context(), thumbKey, thumbData, "image/jpeg"); err != nil {
			log.Printf("s3 upload thumbnail error: %v", err)
			continue
		}

		// Save to DB
		photo, err := h.store.CreatePhoto(folderID, safeFilename, originalKey, thumbKey, contentType, width, height, int64(len(data)), user.ID)
		if err != nil {
			log.Printf("db create photo error: %v", err)
			continue
		}

		uploaded = append(uploaded, *photo)

		// Set as folder cover if first photo
		if folder.CoverKey == "" {
			h.store.UpdateFolderCover(folderID, thumbKey)
			folder.CoverKey = thumbKey
		}
	}

	writeJSON(w, 201, map[string]any{
		"uploaded": len(uploaded),
		"photos":   uploaded,
	})
}

// DeletePhoto removes a photo from S3 and DB.
func (h *Handlers) DeletePhoto(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "invalid photo id")
		return
	}

	photo, err := h.store.DeletePhoto(id)
	if err != nil {
		writeError(w, 404, "photo not found")
		return
	}

	// Delete from S3
	h.s3.Delete(r.Context(), photo.OriginalKey)
	h.s3.Delete(r.Context(), photo.ThumbnailKey)

	writeJSON(w, 200, map[string]string{"status": "deleted"})
}

// SetFolderCover sets the cover image for a folder.
func (h *Handlers) SetFolderCover(w http.ResponseWriter, r *http.Request) {
	folderID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "invalid folder id")
		return
	}

	var req struct {
		PhotoID int64 `json:"photo_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, 400, "invalid request")
		return
	}

	photo, err := h.store.GetPhoto(req.PhotoID)
	if err != nil {
		writeError(w, 404, "photo not found")
		return
	}

	if err := h.store.UpdateFolderCover(folderID, photo.ThumbnailKey); err != nil {
		writeError(w, 500, "failed to set cover")
		return
	}

	writeJSON(w, 200, map[string]string{"status": "ok"})
}

// VenmoQR generates a QR code for the Venmo username.
func (h *Handlers) VenmoQR(w http.ResponseWriter, r *http.Request) {
	if h.config.VenmoUsername == "" {
		http.Error(w, "venmo not configured", http.StatusNotFound)
		return
	}

	venmoURL := fmt.Sprintf("https://venmo.com/u/%s", h.config.VenmoUsername)
	png, err := qrcode.Encode(venmoURL, qrcode.Medium, 256)
	if err != nil {
		http.Error(w, "failed to generate QR", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "public, max-age=86400")
	w.Write(png)
}

// VenmoInfo returns the Venmo configuration.
func (h *Handlers) VenmoInfo(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]string{
		"username": h.config.VenmoUsername,
	})
}

// ListUsers returns all users (admin only).
func (h *Handlers) ListUsers(w http.ResponseWriter, r *http.Request) {
	users, err := h.store.ListUsers()
	if err != nil {
		writeError(w, 500, "failed to list users")
		return
	}
	writeJSON(w, 200, users)
}

// SetUserAdmin promotes/demotes a user (admin only).
func (h *Handlers) SetUserAdmin(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "invalid user id")
		return
	}

	var req struct {
		IsAdmin bool `json:"is_admin"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, 400, "invalid request")
		return
	}

	if err := h.store.SetAdmin(id, req.IsAdmin); err != nil {
		writeError(w, 500, "failed to update user")
		return
	}

	writeJSON(w, 200, map[string]string{"status": "ok"})
}

// ToggleFavorite adds or removes a photo from the user's favorites.
func (h *Handlers) ToggleFavorite(w http.ResponseWriter, r *http.Request) {
	user := auth.GetUser(r)
	if user == nil {
		writeError(w, 401, "login required")
		return
	}

	photoID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "invalid photo id")
		return
	}

	favorited, err := h.store.ToggleFavorite(user.ID, photoID)
	if err != nil {
		writeError(w, 500, "failed to toggle favorite")
		return
	}

	writeJSON(w, 200, map[string]any{"favorited": favorited, "photo_id": photoID})
}

// ListFavorites returns all of the current user's favorited photos.
func (h *Handlers) ListFavorites(w http.ResponseWriter, r *http.Request) {
	user := auth.GetUser(r)
	if user == nil {
		writeError(w, 401, "login required")
		return
	}

	photos, err := h.store.ListFavoritePhotos(user.ID)
	if err != nil {
		writeError(w, 500, "failed to list favorites")
		return
	}
	if photos == nil {
		photos = []db.Photo{}
	}

	type photoResponse struct {
		db.Photo
		ThumbnailURL string `json:"thumbnail_url"`
		OriginalURL  string `json:"original_url"`
		Favorited    bool   `json:"favorited"`
	}
	resp := make([]photoResponse, len(photos))
	for i, p := range photos {
		resp[i] = photoResponse{Photo: p, Favorited: true}
		if url, err := h.s3.PresignedURL(r.Context(), p.ThumbnailKey, 1*time.Hour); err == nil {
			resp[i].ThumbnailURL = url
		}
		if url, err := h.s3.PresignedURL(r.Context(), p.OriginalKey, 1*time.Hour); err == nil {
			resp[i].OriginalURL = url
		}
	}

	writeJSON(w, 200, resp)
}

func generateThumbnail(data []byte, maxSize int) ([]byte, error) {
	img, err := imaging.Decode(bytes.NewReader(data), imaging.AutoOrientation(true))
	if err != nil {
		return nil, fmt.Errorf("decode image: %w", err)
	}

	thumb := imaging.Fit(img, maxSize, maxSize, imaging.Lanczos)

	var buf bytes.Buffer
	if err := imaging.Encode(&buf, thumb, imaging.JPEG, imaging.JPEGQuality(85)); err != nil {
		return nil, fmt.Errorf("encode thumbnail: %w", err)
	}
	return buf.Bytes(), nil
}

func isImageType(ct string) bool {
	return strings.HasPrefix(ct, "image/jpeg") ||
		strings.HasPrefix(ct, "image/png") ||
		strings.HasPrefix(ct, "image/gif") ||
		strings.HasPrefix(ct, "image/webp")
}
