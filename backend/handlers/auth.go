package handlers

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/mail"
	"net/smtp"
	"strings"
	"sync"
	"time"

	"github.com/flodev/iptvplayer/database"
	"github.com/flodev/iptvplayer/middleware"
	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/bcrypt"
)

var (
	SMTPHost        string
	SMTPPort        string
	SMTPUsername    string
	SMTPPassword    string
	SMTPFrom        string
	ResetLinkBase   string
	ResetTokenTTL   = time.Hour
	ResetRateWindow = time.Minute
	ResetRateLimit  = 5

	resetRateMu      sync.Mutex
	resetRateTracker = map[string][]time.Time{}
)

func Register(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "email and password required")
		return
	}

	email, err := normalizeEmail(req.Email)
	if err != nil || req.Password == "" {
		writeError(w, http.StatusBadRequest, "email and password required")
		return
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to hash password")
		return
	}

	res, err := database.DB.Exec(
		`INSERT INTO users (username, email, password_hash) VALUES (?, ?, ?)`,
		email, email, string(hash),
	)
	if err != nil {
		writeError(w, http.StatusConflict, "email already exists")
		return
	}

	id, _ := res.LastInsertId()
	token, err := generateToken(id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to generate token")
		return
	}

	writeJSON(w, http.StatusCreated, map[string]any{
		"token":    token,
		"user_id":  id,
		"username": email,
		"email":    email,
	})
}

func Login(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.Email) == "" || req.Password == "" {
		writeError(w, http.StatusBadRequest, "email and password required")
		return
	}

	id, hash, storedEmail, storedUsername, found := lookupUserByIdentifier(req.Email)
	if !found {
		writeError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}

	if err := bcrypt.CompareHashAndPassword([]byte(hash), []byte(req.Password)); err != nil {
		writeError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}

	token, err := generateToken(id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to generate token")
		return
	}

	identity := storedUsername
	emailValue := ""
	if storedEmail.Valid {
		emailValue = storedEmail.String
		identity = storedEmail.String
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"token":    token,
		"user_id":  id,
		"username": identity,
		"email":    emailValue,
	})
}

// lookupUserByIdentifier finds a user by email (primary) or username (legacy fallback).
// Returns (id, passwordHash, email, username, found).
func lookupUserByIdentifier(identifier string) (int64, string, sql.NullString, string, bool) {
	identifier = strings.TrimSpace(identifier)
	var id int64
	var hash string
	var storedEmail sql.NullString
	var storedUsername string

	// Try email lookup first.
	email, emailErr := normalizeEmail(identifier)
	if emailErr == nil {
		err := database.DB.QueryRow(
			`SELECT id, email, username, password_hash FROM users WHERE lower(email) = lower(?)`, email,
		).Scan(&id, &storedEmail, &storedUsername, &hash)
		if err == nil {
			return id, hash, storedEmail, storedUsername, true
		}
		if err != sql.ErrNoRows {
			return 0, "", sql.NullString{}, "", false
		}
	}

	// Fallback to username for legacy accounts.
	err := database.DB.QueryRow(
		`SELECT id, email, username, password_hash FROM users WHERE username = ?`, identifier,
	).Scan(&id, &storedEmail, &storedUsername, &hash)
	if err != nil {
		return 0, "", sql.NullString{}, "", false
	}
	return id, hash, storedEmail, storedUsername, true
}

func RequestPasswordReset(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email string `json:"email"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "email required")
		return
	}

	email, err := normalizeEmail(req.Email)
	if err != nil {
		writeError(w, http.StatusBadRequest, "email required")
		return
	}

	if !allowResetFor(email, clientIP(r)) {
		writeError(w, http.StatusTooManyRequests, "too many reset requests, try again later")
		return
	}

	cleanupExpiredResetTokens()

	var userID int64
	err = database.DB.QueryRow(`SELECT id FROM users WHERE lower(email) = lower(?)`, email).Scan(&userID)
	if err != nil {
		if err != sql.ErrNoRows {
			log.Printf("request reset lookup failed: %v", err)
		}
		writeJSON(w, http.StatusOK, map[string]string{"message": "If the email exists, a reset link has been sent."})
		return
	}

	rawToken, tokenHash, err := newResetToken()
	if err != nil {
		log.Printf("failed to generate reset token: %v", err)
		writeJSON(w, http.StatusOK, map[string]string{"message": "If the email exists, a reset link has been sent."})
		return
	}

	expiresAt := time.Now().UTC().Add(ResetTokenTTL)
	if _, err := database.DB.Exec(
		`INSERT INTO password_reset_tokens (user_id, token_hash, expires_at) VALUES (?, ?, ?)`,
		userID, tokenHash, expiresAt,
	); err != nil {
		log.Printf("failed to store reset token: %v", err)
		writeJSON(w, http.StatusOK, map[string]string{"message": "If the email exists, a reset link has been sent."})
		return
	}

	if err := sendPasswordResetEmail(email, rawToken); err != nil {
		log.Printf("failed to send reset email: %v", err)
	}

	writeJSON(w, http.StatusOK, map[string]string{"message": "If the email exists, a reset link has been sent."})
}

func VerifyResetToken(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.Token) == "" {
		writeError(w, http.StatusBadRequest, "token required")
		return
	}

	valid, err := isResetTokenValid(req.Token)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid or expired token")
		return
	}

	writeJSON(w, http.StatusOK, map[string]bool{"valid": valid})
}

func ResetPassword(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Token       string `json:"token"`
		NewPassword string `json:"new_password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.Token) == "" || req.NewPassword == "" {
		writeError(w, http.StatusBadRequest, "token and new_password required")
		return
	}

	if len(req.NewPassword) < 8 {
		writeError(w, http.StatusBadRequest, "password must be at least 8 characters")
		return
	}

	tx, err := database.DB.Begin()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to reset password")
		return
	}
	defer tx.Rollback()

	tokenHash := hashResetToken(req.Token)
	var tokenID int64
	var userID int64
	err = tx.QueryRow(`
		SELECT id, user_id
		FROM password_reset_tokens
		WHERE token_hash = ?
		  AND used_at IS NULL
		  AND expires_at > CURRENT_TIMESTAMP
	`, tokenHash).Scan(&tokenID, &userID)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid or expired token")
		return
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to hash password")
		return
	}

	if _, err := tx.Exec(`UPDATE users SET password_hash = ? WHERE id = ?`, string(hash), userID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to reset password")
		return
	}

	if _, err := tx.Exec(`UPDATE password_reset_tokens SET used_at = CURRENT_TIMESTAMP WHERE id = ?`, tokenID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to reset password")
		return
	}

	if err := tx.Commit(); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to reset password")
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"message": "password updated"})
}

func generateToken(userID int64) (string, error) {
	claims := jwt.MapClaims{
		"user_id": userID,
		"exp":     time.Now().Add(365 * 24 * time.Hour).Unix(),
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(middleware.JWTSecret)
}

func normalizeEmail(v string) (string, error) {
	email := strings.ToLower(strings.TrimSpace(v))
	if email == "" {
		return "", fmt.Errorf("email required")
	}
	if _, err := mail.ParseAddress(email); err != nil {
		return "", err
	}
	return email, nil
}

func newResetToken() (string, string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", "", err
	}
	raw := base64.RawURLEncoding.EncodeToString(b)
	return raw, hashResetToken(raw), nil
}

func hashResetToken(token string) string {
	s := sha256.Sum256([]byte(strings.TrimSpace(token)))
	return hex.EncodeToString(s[:])
}

func isResetTokenValid(token string) (bool, error) {
	tokenHash := hashResetToken(token)
	var id int64
	err := database.DB.QueryRow(`
		SELECT id
		FROM password_reset_tokens
		WHERE token_hash = ?
		  AND used_at IS NULL
		  AND expires_at > CURRENT_TIMESTAMP
		LIMIT 1
	`, tokenHash).Scan(&id)
	if err != nil {
		if err == sql.ErrNoRows {
			return false, err
		}
		return false, err
	}
	return id > 0, nil
}

func cleanupExpiredResetTokens() {
	if _, err := database.DB.Exec(`DELETE FROM password_reset_tokens WHERE used_at IS NOT NULL OR expires_at <= CURRENT_TIMESTAMP`); err != nil {
		log.Printf("failed to cleanup reset tokens: %v", err)
	}
}

func sendPasswordResetEmail(toEmail, rawToken string) error {
	if SMTPHost == "" || SMTPPort == "" || SMTPFrom == "" {
		log.Printf("SMTP not configured, reset token for %s: %s", toEmail, rawToken)
		return nil
	}

	resetLink := strings.TrimRight(ResetLinkBase, "/")
	if resetLink != "" {
		resetLink = fmt.Sprintf("%s/reset-password?token=%s", resetLink, rawToken)
	}

	body := "Use this token to reset your password: " + rawToken + "\n\n"
	if resetLink != "" {
		body += "Open this link in the app: " + resetLink + "\n\n"
	}
	body += fmt.Sprintf("This token expires in %d minutes. If you did not request this, you can ignore this email.\n", int(ResetTokenTTL.Minutes()))

	msg := []byte("Subject: IPTV Player password reset\r\n" +
		"MIME-Version: 1.0\r\n" +
		"Content-Type: text/plain; charset=\"UTF-8\"\r\n\r\n" +
		body)

	addr := net.JoinHostPort(SMTPHost, SMTPPort)
	var auth smtp.Auth
	if SMTPUsername != "" {
		auth = smtp.PlainAuth("", SMTPUsername, SMTPPassword, SMTPHost)
	}

	return smtp.SendMail(addr, auth, SMTPFrom, []string{toEmail}, msg)
}

func allowResetFor(email, ip string) bool {
	now := time.Now()
	windowStart := now.Add(-ResetRateWindow)
	keys := []string{"email:" + email, "ip:" + ip}

	resetRateMu.Lock()
	defer resetRateMu.Unlock()

	for _, key := range keys {
		hits := resetRateTracker[key]
		trimmed := make([]time.Time, 0, len(hits)+1)
		for _, t := range hits {
			if t.After(windowStart) {
				trimmed = append(trimmed, t)
			}
		}
		if len(trimmed) >= ResetRateLimit {
			resetRateTracker[key] = trimmed
			return false
		}
		trimmed = append(trimmed, now)
		resetRateTracker[key] = trimmed
	}

	return true
}

func clientIP(r *http.Request) string {
	if xff := strings.TrimSpace(r.Header.Get("X-Forwarded-For")); xff != "" {
		parts := strings.Split(xff, ",")
		if len(parts) > 0 {
			return strings.TrimSpace(parts[0])
		}
	}
	hostPort := strings.TrimSpace(r.RemoteAddr)
	host, _, err := net.SplitHostPort(hostPort)
	if err == nil {
		return host
	}
	return hostPort
}
