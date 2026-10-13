package handlers

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/flodev/iptvplayer/database"
	"github.com/flodev/iptvplayer/middleware"
	"github.com/go-chi/chi/v5"
	"golang.org/x/crypto/bcrypt"
)

// TVRoutes keeps old TV password approvals while providing bearer approvals.
func TVRoutes(r chi.Router) {
	r.Post("/auth/tv/start", StartTVLogin)
	r.Get("/auth/tv/poll", PollTVLogin)
	r.Post("/auth/tv/approve", ApproveTVLogin)
	r.Get("/auth/tv/session", TVLoginSession)
	r.Post("/auth/tv/lookup", LookupTVLogin)
	r.With(tvBearerAuth).Post("/auth/tv/approve-session", ApproveTVSession)
	r.With(tvBearerAuth).Post("/auth/tv/decline-session", DeclineTVSession)
}

func tvBearerAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
			writeError(w, http.StatusUnauthorized, "sign in to approve this TV")
			return
		}
		middleware.Auth(next).ServeHTTP(w, r)
	})
}

func StartTVLogin(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	cleanupExpiredTVLoginSessions()
	deviceCode, deviceHash, err := newTVDeviceCode()
	if err != nil {
		writeError(w, 500, "failed to generate device code")
		return
	}
	pairingToken, _, err := newTVDeviceCode()
	if err != nil {
		writeError(w, 500, "failed to generate approval token")
		return
	}
	expiresAt := time.Now().UTC().Add(TVLoginTTL)
	// A unique index prevents ambiguous manual codes; retry random collisions.
	for attempt := 0; attempt < 8; attempt++ {
		userCode, userHash, err := newTVUserCode(deviceCode)
		if err != nil {
			writeError(w, 500, "failed to generate TV code")
			return
		}
		_, err = database.DB.Exec(`INSERT INTO tv_login_sessions
   (device_code_hash,user_code_hash,pairing_token,pairing_token_hash,user_code,expires_at)
   VALUES(?,?,?,?,?,?)`, deviceHash, userHash, pairingToken, hashTVPairingToken(pairingToken), userCode, expiresAt.Format(time.RFC3339Nano))
		if err == nil {
			writeJSON(w, http.StatusCreated, map[string]any{"device_code": deviceCode, "user_code": userCode, "pairing_token": pairingToken, "expires_at": expiresAt.Format(time.RFC3339), "poll_interval_seconds": 3})
			return
		}
		if !strings.Contains(err.Error(), "tv_login_sessions.user_code") {
			break
		}
	}
	writeError(w, 500, "failed to create login session")
}

type tvSession struct {
	ID                                int64
	UserCode, DeviceName              string
	ExpiresAt                         time.Time
	ApprovedAt, ClaimedAt, DeclinedAt sql.NullTime
}

func findTVSession(pairingToken string) (tvSession, error) {
	var s tvSession
	err := database.DB.QueryRow(`SELECT id, user_code, device_name, expires_at, approved_at, claimed_at, declined_at
  FROM tv_login_sessions WHERE pairing_token_hash=?`, hashTVPairingToken(pairingToken)).Scan(&s.ID, &s.UserCode, &s.DeviceName, &s.ExpiresAt, &s.ApprovedAt, &s.ClaimedAt, &s.DeclinedAt)
	return s, err
}

func validTVSession(w http.ResponseWriter, token string) (tvSession, bool) {
	if !validPairingToken(token) {
		writeError(w, 400, "valid pairing_token required")
		return tvSession{}, false
	}
	s, err := findTVSession(token)
	if err != nil {
		writeError(w, 404, "TV request not found; scan a new QR code")
		return s, false
	}
	if s.ClaimedAt.Valid || !s.ExpiresAt.After(time.Now().UTC()) {
		writeError(w, 410, "TV request expired or used; generate a new code on your TV")
		return s, false
	}
	return s, true
}

func TVLoginSession(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	s, ok := validTVSession(w, strings.TrimSpace(r.URL.Query().Get("pairing_token")))
	if !ok {
		return
	}
	status := "pending"
	if s.ApprovedAt.Valid {
		status = "approved"
	} else if s.DeclinedAt.Valid {
		status = "declined"
	}
	writeJSON(w, 200, map[string]any{"user_code": s.UserCode, "device_name": s.DeviceName, "expires_at": s.ExpiresAt.Format(time.RFC3339), "status": status})
}

func LookupTVLogin(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !tvLookupLimiter.allow(r) {
		w.Header().Set("Retry-After", "60")
		writeError(w, 429, "too many code attempts; try again in a minute")
		return
	}
	var req struct {
		UserCode string `json:"user_code"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&req); err != nil {
		writeError(w, 400, "six-digit user_code required")
		return
	}
	code := strings.TrimSpace(req.UserCode)
	if len(code) != 6 || strings.IndexFunc(code, func(c rune) bool { return c < '0' || c > '9' }) != -1 {
		writeError(w, 400, "six-digit user_code required")
		return
	}
	var token string
	err := database.DB.QueryRow(`SELECT pairing_token FROM tv_login_sessions
  WHERE user_code=? AND claimed_at IS NULL AND declined_at IS NULL AND approved_at IS NULL
  AND julianday(replace(expires_at, ' +0000 UTC', ''))>julianday(?)`, code, time.Now().UTC().Format(time.RFC3339Nano)).Scan(&token)
	if err != nil {
		writeError(w, 404, "code not found or expired; generate a new code on your TV")
		return
	}
	writeJSON(w, 200, map[string]string{"pairing_token": token})
}

func pairingTokenBody(w http.ResponseWriter, r *http.Request) (string, bool) {
	var req struct {
		PairingToken string `json:"pairing_token"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&req); err != nil {
		writeError(w, 400, "pairing_token required")
		return "", false
	}
	token := strings.TrimSpace(req.PairingToken)
	if !validPairingToken(token) {
		writeError(w, 400, "valid pairing_token required")
		return "", false
	}
	return token, true
}

func verifiedTVAccount(w http.ResponseWriter, r *http.Request) (int64, string, string, bool) {
	id := middleware.GetUserID(r)
	var username string
	var email sql.NullString
	var verified bool
	if id == 0 {
		writeError(w, 401, "sign in to approve this TV")
		return 0, "", "", false
	}
	err := database.DB.QueryRow(`SELECT username,email,email_verified FROM users WHERE id=?`, id).Scan(&username, &email, &verified)
	if err != nil {
		writeError(w, 401, "account no longer available")
		return 0, "", "", false
	}
	if !verified {
		writeError(w, 403, "verify your email before approving a TV")
		return 0, "", "", false
	}
	if email.Valid {
		username = email.String
	}
	return id, username, email.String, true
}

func ApproveTVSession(w http.ResponseWriter, r *http.Request) {
	id, username, email, ok := verifiedTVAccount(w, r)
	if !ok {
		return
	}
	token, ok := pairingTokenBody(w, r)
	if !ok {
		return
	}
	s, ok := validTVSession(w, token)
	if !ok {
		return
	}
	approveTVSession(w, s.ID, id, username, email)
}

func approveTVSession(w http.ResponseWriter, sessionID, userID int64, username, email string) {
	token, err := generateToken(userID)
	if err != nil {
		writeError(w, 500, "failed to generate TV token")
		return
	}
	result, err := database.DB.Exec(`UPDATE tv_login_sessions
  SET approved_at=CURRENT_TIMESTAMP, approved_user_id=?, approved_token=?, approved_username=?, approved_email=?
  WHERE id=? AND approved_at IS NULL AND claimed_at IS NULL AND declined_at IS NULL
  AND julianday(replace(expires_at, ' +0000 UTC', ''))>julianday(?)
  AND EXISTS(SELECT 1 FROM users WHERE id=? AND email_verified=1)`, userID, token, username, email, sessionID, time.Now().UTC().Format(time.RFC3339Nano), userID)
	if err != nil {
		writeError(w, 500, "failed to approve TV login")
		return
	}
	rows, _ := result.RowsAffected()
	if rows != 1 {
		writeError(w, 409, "TV request is no longer pending")
		return
	}
	writeJSON(w, 200, map[string]string{"message": "TV login approved", "status": "approved"})
}

func DeclineTVSession(w http.ResponseWriter, r *http.Request) {
	_, _, _, ok := verifiedTVAccount(w, r)
	if !ok {
		return
	}
	token, ok := pairingTokenBody(w, r)
	if !ok {
		return
	}
	s, ok := validTVSession(w, token)
	if !ok {
		return
	}
	result, err := database.DB.Exec(`UPDATE tv_login_sessions SET declined_at=CURRENT_TIMESTAMP
  WHERE id=? AND approved_at IS NULL AND claimed_at IS NULL AND declined_at IS NULL
  AND julianday(replace(expires_at, ' +0000 UTC', ''))>julianday(?)`, s.ID, time.Now().UTC().Format(time.RFC3339Nano))
	if err != nil {
		writeError(w, 500, "failed to decline TV login")
		return
	}
	rows, _ := result.RowsAffected()
	if rows != 1 {
		writeError(w, 409, "TV request is no longer pending")
		return
	}
	writeJSON(w, 200, map[string]string{"message": "TV login declined", "status": "declined"})
}

// ApproveTVLogin is the legacy password/code endpoint for installed older TVs.
func ApproveTVLogin(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	var req struct {
		DeviceCode string `json:"device_code"`
		UserCode   string `json:"user_code"`
		Email      string `json:"email"`
		Password   string `json:"password"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil || strings.TrimSpace(req.DeviceCode) == "" || strings.TrimSpace(req.UserCode) == "" || strings.TrimSpace(req.Email) == "" || req.Password == "" {
		writeError(w, 400, "device_code, user_code, email and password required")
		return
	}
	var sessionID int64
	var storedHash string
	var approved, declined sql.NullTime
	err := database.DB.QueryRow(`SELECT id,user_code_hash,approved_at,declined_at FROM tv_login_sessions
  WHERE device_code_hash=? AND claimed_at IS NULL AND julianday(replace(expires_at, ' +0000 UTC', ''))>julianday(?)`, hashTVDeviceCode(req.DeviceCode), time.Now().UTC().Format(time.RFC3339Nano)).Scan(&sessionID, &storedHash, &approved, &declined)
	if err != nil || storedHash != hashTVUserCode(req.DeviceCode, req.UserCode) {
		writeError(w, 401, "invalid or expired TV login session")
		return
	}
	id, hash, email, username, verified, found := lookupUserByIdentifier(req.Email)
	if !found || bcrypt.CompareHashAndPassword([]byte(hash), []byte(req.Password)) != nil {
		writeError(w, 401, "invalid credentials")
		return
	}
	if !verified {
		writeError(w, 403, "email not verified")
		return
	}
	if approved.Valid || declined.Valid {
		writeError(w, 409, "TV request is no longer pending")
		return
	}
	if email.Valid {
		username = email.String
	}
	approveTVSession(w, sessionID, id, username, email.String)
}

func PollTVLogin(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	code := strings.TrimSpace(r.URL.Query().Get("device_code"))
	if code == "" || len(code) > 128 {
		writeError(w, 400, "device_code required")
		return
	}
	// Read and claim inside a transaction so concurrent polls cannot both get a token.
	tx, err := database.DB.Begin()
	if err != nil {
		writeError(w, 500, "failed to read TV login")
		return
	}
	defer tx.Rollback()
	var id int64
	var approved, claimed, declined sql.NullTime
	var expires time.Time
	var token, username, email sql.NullString
	var userID sql.NullInt64
	err = tx.QueryRow(`SELECT id,approved_at,claimed_at,declined_at,expires_at,approved_token,approved_user_id,approved_username,approved_email
  FROM tv_login_sessions WHERE device_code_hash=?`, hashTVDeviceCode(code)).Scan(&id, &approved, &claimed, &declined, &expires, &token, &userID, &username, &email)
	if err != nil {
		writeError(w, 401, "invalid or expired TV login session")
		return
	}
	if claimed.Valid {
		writeError(w, 410, "TV login session already used")
		return
	}
	if !expires.After(time.Now().UTC()) {
		writeError(w, 410, "TV login session expired")
		return
	}
	if declined.Valid {
		writeJSON(w, 200, map[string]string{"status": "declined", "expires_at": expires.Format(time.RFC3339)})
		return
	}
	if !approved.Valid {
		writeJSON(w, 200, map[string]string{"status": "pending", "expires_at": expires.Format(time.RFC3339)})
		return
	}
	result, err := tx.Exec(`UPDATE tv_login_sessions SET claimed_at=CURRENT_TIMESTAMP, approved_token=NULL
  WHERE id=? AND claimed_at IS NULL AND declined_at IS NULL AND approved_at IS NOT NULL
  AND julianday(replace(expires_at, ' +0000 UTC', ''))>julianday(?)`, id, time.Now().UTC().Format(time.RFC3339Nano))
	if err != nil {
		writeError(w, 500, "failed to complete TV login")
		return
	}
	rows, _ := result.RowsAffected()
	if rows != 1 {
		writeError(w, 410, "TV login session expired or used")
		return
	}
	if err := tx.Commit(); err != nil {
		writeError(w, 500, "failed to complete TV login")
		return
	}
	writeJSON(w, 200, map[string]any{"status": "approved", "auth": map[string]any{"token": token.String, "user_id": userID.Int64, "username": username.String, "email": email.String}})
}

func hashTVPairingToken(token string) string {
	sum := sha256.Sum256([]byte("tv-pairing:" + token))
	return hex.EncodeToString(sum[:])
}

func validPairingToken(token string) bool {
	return len(token) >= 32 && len(token) <= 128 && strings.IndexFunc(token, func(c rune) bool {
		return !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-')
	}) == -1
}

type rateEntry struct {
	start time.Time
	count int
}
type pairingRateLimiter struct {
	mu      sync.Mutex
	entries map[string]rateEntry
	total   rateEntry
}

var tvLookupLimiter = pairingRateLimiter{entries: map[string]rateEntry{}}

func (limiter *pairingRateLimiter) allow(r *http.Request) bool {
	// Forwarded headers are user controlled unless the proxy overwrites them.
	// Using the socket peer deliberately groups requests behind an untrusted proxy.
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	now := time.Now()
	limiter.mu.Lock()
	defer limiter.mu.Unlock()
	for key, entry := range limiter.entries {
		if now.Sub(entry.start) >= time.Minute {
			delete(limiter.entries, key)
		}
	}
	if now.Sub(limiter.total.start) >= time.Minute {
		limiter.total = rateEntry{start: now}
	}
	limiter.total.count++
	if limiter.total.count > 120 {
		return false
	}
	entry, found := limiter.entries[host]
	if !found {
		if len(limiter.entries) >= 4096 {
			return false
		}
		entry = rateEntry{start: now}
	}
	entry.count++
	limiter.entries[host] = entry
	return entry.count <= 5
}
