package auth

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"photo-share/internal/config"
	"photo-share/internal/db"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
)

type contextKey string

const userContextKey contextKey = "user"

type GoogleUserInfo struct {
	ID      string `json:"id"`
	Email   string `json:"email"`
	Name    string `json:"name"`
	Picture string `json:"picture"`
}

type Auth struct {
	oauth  *oauth2.Config
	store  *db.Store
	config *config.Config
}

func New(cfg *config.Config, store *db.Store) *Auth {
	return &Auth{
		oauth: &oauth2.Config{
			ClientID:     cfg.GoogleClientID,
			ClientSecret: cfg.GoogleSecret,
			RedirectURL:  strings.TrimRight(cfg.BaseURL, "/") + "/auth/callback",
			Scopes:       []string{"openid", "email", "profile"},
			Endpoint:     google.Endpoint,
		},
		store:  store,
		config: cfg,
	}
}

// LoginHandler redirects to Google's OAuth consent page.
func (a *Auth) LoginHandler(w http.ResponseWriter, r *http.Request) {
	url := a.oauth.AuthCodeURL("state", oauth2.AccessTypeOffline)
	http.Redirect(w, r, url, http.StatusTemporaryRedirect)
}

// CallbackHandler handles the OAuth callback from Google.
func (a *Auth) CallbackHandler(w http.ResponseWriter, r *http.Request) {
	code := r.URL.Query().Get("code")
	if code == "" {
		http.Error(w, "missing code", http.StatusBadRequest)
		return
	}

	token, err := a.oauth.Exchange(r.Context(), code)
	if err != nil {
		log.Printf("oauth exchange error: %v", err)
		http.Error(w, "auth failed", http.StatusInternalServerError)
		return
	}

	userInfo, err := a.fetchGoogleUser(r.Context(), token)
	if err != nil {
		log.Printf("fetch user info error: %v", err)
		http.Error(w, "failed to get user info", http.StatusInternalServerError)
		return
	}

	user, err := a.store.UpsertUser(userInfo.ID, userInfo.Email, userInfo.Name, userInfo.Picture)
	if err != nil {
		log.Printf("upsert user error: %v", err)
		http.Error(w, "failed to save user", http.StatusInternalServerError)
		return
	}

	sessionToken, err := a.store.CreateSession(user.ID)
	if err != nil {
		log.Printf("create session error: %v", err)
		http.Error(w, "failed to create session", http.StatusInternalServerError)
		return
	}

	http.SetCookie(w, &http.Cookie{
		Name:     "session",
		Value:    sessionToken,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   30 * 24 * 3600,
	})

	http.Redirect(w, r, "/", http.StatusTemporaryRedirect)
}

// LogoutHandler clears the session.
func (a *Auth) LogoutHandler(w http.ResponseWriter, r *http.Request) {
	cookie, err := r.Cookie("session")
	if err == nil {
		a.store.DeleteSession(cookie.Value)
	}

	http.SetCookie(w, &http.Cookie{
		Name:     "session",
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		MaxAge:   -1,
	})

	http.Redirect(w, r, "/", http.StatusTemporaryRedirect)
}

// SessionMiddleware loads the current user from the session cookie.
func (a *Auth) SessionMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cookie, err := r.Cookie("session")
		if err != nil {
			next.ServeHTTP(w, r)
			return
		}

		sess, err := a.store.GetSession(cookie.Value)
		if err != nil {
			next.ServeHTTP(w, r)
			return
		}

		user, err := a.store.GetUser(sess.UserID)
		if err != nil {
			next.ServeHTTP(w, r)
			return
		}

		ctx := context.WithValue(r.Context(), userContextKey, user)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// RequireAdmin is middleware that requires the user to be an admin.
func RequireAdmin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		user := GetUser(r)
		if user == nil || !user.IsAdmin {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		next(w, r)
	}
}

// GetUser returns the current user from the request context.
func GetUser(r *http.Request) *db.User {
	user, _ := r.Context().Value(userContextKey).(*db.User)
	return user
}

func (a *Auth) fetchGoogleUser(ctx context.Context, token *oauth2.Token) (*GoogleUserInfo, error) {
	client := a.oauth.Client(ctx, token)

	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, "GET", "https://www.googleapis.com/oauth2/v2/userinfo", nil)
	if err != nil {
		return nil, err
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("google userinfo request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("google userinfo status: %d", resp.StatusCode)
	}

	var info GoogleUserInfo
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return nil, fmt.Errorf("decode userinfo: %w", err)
	}
	return &info, nil
}

// MeHandler returns the current user as JSON.
func (a *Auth) MeHandler(w http.ResponseWriter, r *http.Request) {
	user := GetUser(r)
	w.Header().Set("Content-Type", "application/json")
	if user == nil {
		json.NewEncoder(w).Encode(map[string]any{"logged_in": false})
		return
	}
	json.NewEncoder(w).Encode(map[string]any{
		"logged_in": true,
		"id":        user.ID,
		"email":     user.Email,
		"name":      user.Name,
		"avatar":    user.AvatarURL,
		"is_admin":  user.IsAdmin,
	})
}
