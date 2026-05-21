package db

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

type User struct {
	ID        int64
	GoogleID  string
	Email     string
	Name      string
	AvatarURL string
	IsAdmin   bool
	CreatedAt time.Time
}

type Folder struct {
	ID         int64
	Name       string
	Slug       string
	ParentID   *int64
	CoverKey   string
	PhotoCount int
	CreatedAt  time.Time
	CreatedBy  int64
}

type Photo struct {
	ID           int64
	FolderID     int64
	Filename     string
	OriginalKey  string
	ThumbnailKey string
	ContentType  string
	Width        int
	Height       int
	Size         int64
	UploadedBy   int64
	CreatedAt    time.Time
}

type Session struct {
	Token     string
	UserID    int64
	ExpiresAt time.Time
}

type Store struct {
	db          *sql.DB
	adminEmails []string
}

func New(dataDir string, adminEmails []string) (*Store, error) {
	if err := os.MkdirAll(dataDir, 0755); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}

	dbPath := filepath.Join(dataDir, "photos.db")
	db, err := sql.Open("sqlite", dbPath+"?_journal_mode=WAL&_busy_timeout=5000")
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}

	s := &Store{db: db, adminEmails: adminEmails}
	if err := s.migrate(); err != nil {
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return s, nil
}

func (s *Store) migrate() error {
	_, err := s.db.Exec(`
		CREATE TABLE IF NOT EXISTS users (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			google_id TEXT UNIQUE NOT NULL,
			email TEXT UNIQUE NOT NULL,
			name TEXT NOT NULL DEFAULT '',
			avatar_url TEXT NOT NULL DEFAULT '',
			is_admin BOOLEAN NOT NULL DEFAULT FALSE,
			created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
		);
		CREATE TABLE IF NOT EXISTS folders (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			name TEXT NOT NULL,
			slug TEXT UNIQUE NOT NULL,
			parent_id INTEGER REFERENCES folders(id) ON DELETE CASCADE,
			cover_key TEXT NOT NULL DEFAULT '',
			created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			created_by INTEGER NOT NULL REFERENCES users(id)
		);
		CREATE TABLE IF NOT EXISTS photos (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
			filename TEXT NOT NULL,
			original_key TEXT NOT NULL,
			thumbnail_key TEXT NOT NULL,
			content_type TEXT NOT NULL DEFAULT 'image/jpeg',
			width INTEGER NOT NULL DEFAULT 0,
			height INTEGER NOT NULL DEFAULT 0,
			size INTEGER NOT NULL DEFAULT 0,
			uploaded_by INTEGER NOT NULL REFERENCES users(id),
			created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
		);
		CREATE TABLE IF NOT EXISTS sessions (
			token TEXT PRIMARY KEY,
			user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
			expires_at DATETIME NOT NULL
		);
		CREATE TABLE IF NOT EXISTS favorites (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
			photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
			created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			UNIQUE(user_id, photo_id)
		);
		CREATE INDEX IF NOT EXISTS idx_photos_folder ON photos(folder_id);
		CREATE INDEX IF NOT EXISTS idx_folders_parent ON folders(parent_id);
		CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at);
		CREATE INDEX IF NOT EXISTS idx_favorites_user ON favorites(user_id);
	`)
	return err
}

func (s *Store) Close() error {
	return s.db.Close()
}

// UpsertUser creates or updates a user from Google OAuth data.
func (s *Store) UpsertUser(googleID, email, name, avatarURL string) (*User, error) {
	email = strings.ToLower(email)
	isAdmin := s.isAdminEmail(email)

	_, err := s.db.Exec(`
		INSERT INTO users (google_id, email, name, avatar_url, is_admin)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(google_id) DO UPDATE SET
			email = excluded.email,
			name = excluded.name,
			avatar_url = excluded.avatar_url
	`, googleID, email, name, avatarURL, isAdmin)
	if err != nil {
		return nil, err
	}

	return s.GetUserByGoogleID(googleID)
}

func (s *Store) isAdminEmail(email string) bool {
	for _, e := range s.adminEmails {
		if e == email {
			return true
		}
	}
	// If no admin emails configured, first user becomes admin
	if len(s.adminEmails) == 0 {
		var count int
		s.db.QueryRow("SELECT COUNT(*) FROM users").Scan(&count)
		return count == 0
	}
	return false
}

func (s *Store) GetUser(id int64) (*User, error) {
	u := &User{}
	err := s.db.QueryRow(`
		SELECT id, google_id, email, name, avatar_url, is_admin, created_at
		FROM users WHERE id = ?
	`, id).Scan(&u.ID, &u.GoogleID, &u.Email, &u.Name, &u.AvatarURL, &u.IsAdmin, &u.CreatedAt)
	if err != nil {
		return nil, err
	}
	return u, nil
}

func (s *Store) GetUserByGoogleID(googleID string) (*User, error) {
	u := &User{}
	err := s.db.QueryRow(`
		SELECT id, google_id, email, name, avatar_url, is_admin, created_at
		FROM users WHERE google_id = ?
	`, googleID).Scan(&u.ID, &u.GoogleID, &u.Email, &u.Name, &u.AvatarURL, &u.IsAdmin, &u.CreatedAt)
	if err != nil {
		return nil, err
	}
	return u, nil
}

func (s *Store) SetAdmin(userID int64, isAdmin bool) error {
	_, err := s.db.Exec("UPDATE users SET is_admin = ? WHERE id = ?", isAdmin, userID)
	return err
}

func (s *Store) ListUsers() ([]User, error) {
	rows, err := s.db.Query(`
		SELECT id, google_id, email, name, avatar_url, is_admin, created_at
		FROM users ORDER BY created_at
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var users []User
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.GoogleID, &u.Email, &u.Name, &u.AvatarURL, &u.IsAdmin, &u.CreatedAt); err != nil {
			return nil, err
		}
		users = append(users, u)
	}
	return users, nil
}

// Session management
func (s *Store) CreateSession(userID int64) (string, error) {
	token := generateToken()
	expiresAt := time.Now().Add(30 * 24 * time.Hour)
	_, err := s.db.Exec(
		"INSERT INTO sessions (token, user_id, expires_at) VALUES (?, ?, ?)",
		token, userID, expiresAt,
	)
	if err != nil {
		return "", err
	}
	return token, nil
}

func (s *Store) GetSession(token string) (*Session, error) {
	sess := &Session{}
	err := s.db.QueryRow(
		"SELECT token, user_id, expires_at FROM sessions WHERE token = ? AND expires_at > ?",
		token, time.Now(),
	).Scan(&sess.Token, &sess.UserID, &sess.ExpiresAt)
	if err != nil {
		return nil, err
	}
	return sess, nil
}

func (s *Store) DeleteSession(token string) error {
	_, err := s.db.Exec("DELETE FROM sessions WHERE token = ?", token)
	return err
}

func (s *Store) CleanExpiredSessions() {
	s.db.Exec("DELETE FROM sessions WHERE expires_at < ?", time.Now())
}

// Folder operations
func (s *Store) CreateFolder(name, slug string, parentID *int64, createdBy int64) (*Folder, error) {
	res, err := s.db.Exec(
		"INSERT INTO folders (name, slug, parent_id, created_by) VALUES (?, ?, ?, ?)",
		name, slug, parentID, createdBy,
	)
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	return s.GetFolder(id)
}

func (s *Store) GetFolder(id int64) (*Folder, error) {
	f := &Folder{}
	err := s.db.QueryRow(`
		SELECT f.id, f.name, f.slug, f.parent_id, f.cover_key, f.created_at, f.created_by,
		       (SELECT COUNT(*) FROM photos WHERE folder_id = f.id) as photo_count
		FROM folders f WHERE f.id = ?
	`, id).Scan(&f.ID, &f.Name, &f.Slug, &f.ParentID, &f.CoverKey, &f.CreatedAt, &f.CreatedBy, &f.PhotoCount)
	if err != nil {
		return nil, err
	}
	return f, nil
}

func (s *Store) GetFolderBySlug(slug string) (*Folder, error) {
	f := &Folder{}
	err := s.db.QueryRow(`
		SELECT f.id, f.name, f.slug, f.parent_id, f.cover_key, f.created_at, f.created_by,
		       (SELECT COUNT(*) FROM photos WHERE folder_id = f.id) as photo_count
		FROM folders f WHERE f.slug = ?
	`, slug).Scan(&f.ID, &f.Name, &f.Slug, &f.ParentID, &f.CoverKey, &f.CreatedAt, &f.CreatedBy, &f.PhotoCount)
	if err != nil {
		return nil, err
	}
	return f, nil
}

func (s *Store) ListFolders(parentID *int64) ([]Folder, error) {
	var rows *sql.Rows
	var err error
	if parentID == nil {
		rows, err = s.db.Query(`
			SELECT f.id, f.name, f.slug, f.parent_id, f.cover_key, f.created_at, f.created_by,
			       (SELECT COUNT(*) FROM photos WHERE folder_id = f.id) as photo_count
			FROM folders f WHERE f.parent_id IS NULL ORDER BY f.created_at DESC
		`)
	} else {
		rows, err = s.db.Query(`
			SELECT f.id, f.name, f.slug, f.parent_id, f.cover_key, f.created_at, f.created_by,
			       (SELECT COUNT(*) FROM photos WHERE folder_id = f.id) as photo_count
			FROM folders f WHERE f.parent_id = ? ORDER BY f.created_at DESC
		`, *parentID)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var folders []Folder
	for rows.Next() {
		var f Folder
		if err := rows.Scan(&f.ID, &f.Name, &f.Slug, &f.ParentID, &f.CoverKey, &f.CreatedAt, &f.CreatedBy, &f.PhotoCount); err != nil {
			return nil, err
		}
		folders = append(folders, f)
	}
	return folders, nil
}

func (s *Store) UpdateFolderCover(folderID int64, coverKey string) error {
	_, err := s.db.Exec("UPDATE folders SET cover_key = ? WHERE id = ?", coverKey, folderID)
	return err
}

func (s *Store) RenameFolder(id int64, name, slug string) error {
	_, err := s.db.Exec("UPDATE folders SET name = ?, slug = ? WHERE id = ?", name, slug, id)
	return err
}

func (s *Store) DeleteFolder(id int64) error {
	_, err := s.db.Exec("DELETE FROM folders WHERE id = ?", id)
	return err
}

// Photo operations
func (s *Store) CreatePhoto(folderID int64, filename, originalKey, thumbnailKey, contentType string, width, height int, size int64, uploadedBy int64) (*Photo, error) {
	res, err := s.db.Exec(`
		INSERT INTO photos (folder_id, filename, original_key, thumbnail_key, content_type, width, height, size, uploaded_by)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, folderID, filename, originalKey, thumbnailKey, contentType, width, height, size, uploadedBy)
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	return s.GetPhoto(id)
}

func (s *Store) GetPhoto(id int64) (*Photo, error) {
	p := &Photo{}
	err := s.db.QueryRow(`
		SELECT id, folder_id, filename, original_key, thumbnail_key, content_type, width, height, size, uploaded_by, created_at
		FROM photos WHERE id = ?
	`, id).Scan(&p.ID, &p.FolderID, &p.Filename, &p.OriginalKey, &p.ThumbnailKey, &p.ContentType, &p.Width, &p.Height, &p.Size, &p.UploadedBy, &p.CreatedAt)
	if err != nil {
		return nil, err
	}
	return p, nil
}

func (s *Store) ListPhotos(folderID int64) ([]Photo, error) {
	rows, err := s.db.Query(`
		SELECT id, folder_id, filename, original_key, thumbnail_key, content_type, width, height, size, uploaded_by, created_at
		FROM photos WHERE folder_id = ? ORDER BY created_at DESC
	`, folderID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var photos []Photo
	for rows.Next() {
		var p Photo
		if err := rows.Scan(&p.ID, &p.FolderID, &p.Filename, &p.OriginalKey, &p.ThumbnailKey, &p.ContentType, &p.Width, &p.Height, &p.Size, &p.UploadedBy, &p.CreatedAt); err != nil {
			return nil, err
		}
		photos = append(photos, p)
	}
	return photos, nil
}

func (s *Store) DeletePhoto(id int64) (*Photo, error) {
	p, err := s.GetPhoto(id)
	if err != nil {
		return nil, err
	}
	_, err = s.db.Exec("DELETE FROM photos WHERE id = ?", id)
	if err != nil {
		return nil, err
	}
	return p, nil
}

// GetFolderPhotosForKeys returns all S3 keys for photos in a folder (for bulk deletion).
func (s *Store) GetFolderPhotoKeys(folderID int64) (originals, thumbnails []string, err error) {
	rows, err := s.db.Query("SELECT original_key, thumbnail_key FROM photos WHERE folder_id = ?", folderID)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()

	for rows.Next() {
		var ok, tk string
		if err := rows.Scan(&ok, &tk); err != nil {
			return nil, nil, err
		}
		originals = append(originals, ok)
		thumbnails = append(thumbnails, tk)
	}
	return
}

func generateToken() string {
	b := make([]byte, 32)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// Favorite operations
func (s *Store) ToggleFavorite(userID, photoID int64) (favorited bool, err error) {
	// Try to delete first; if it existed, it was unfavorited
	res, err := s.db.Exec("DELETE FROM favorites WHERE user_id = ? AND photo_id = ?", userID, photoID)
	if err != nil {
		return false, err
	}
	rows, _ := res.RowsAffected()
	if rows > 0 {
		return false, nil
	}
	// Didn't exist, insert it
	_, err = s.db.Exec("INSERT INTO favorites (user_id, photo_id) VALUES (?, ?)", userID, photoID)
	if err != nil {
		return false, err
	}
	return true, nil
}

func (s *Store) GetUserFavoriteIDs(userID int64) (map[int64]bool, error) {
	rows, err := s.db.Query("SELECT photo_id FROM favorites WHERE user_id = ?", userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	faves := make(map[int64]bool)
	for rows.Next() {
		var pid int64
		if err := rows.Scan(&pid); err != nil {
			return nil, err
		}
		faves[pid] = true
	}
	return faves, nil
}

func (s *Store) ListFavoritePhotos(userID int64) ([]Photo, error) {
	rows, err := s.db.Query(`
		SELECT p.id, p.folder_id, p.filename, p.original_key, p.thumbnail_key,
		       p.content_type, p.width, p.height, p.size, p.uploaded_by, p.created_at
		FROM photos p
		JOIN favorites f ON f.photo_id = p.id
		WHERE f.user_id = ?
		ORDER BY f.created_at DESC
	`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var photos []Photo
	for rows.Next() {
		var p Photo
		if err := rows.Scan(&p.ID, &p.FolderID, &p.Filename, &p.OriginalKey, &p.ThumbnailKey, &p.ContentType, &p.Width, &p.Height, &p.Size, &p.UploadedBy, &p.CreatedAt); err != nil {
			return nil, err
		}
		photos = append(photos, p)
	}
	return photos, nil
}
