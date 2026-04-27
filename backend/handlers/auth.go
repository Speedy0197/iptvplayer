package handlers

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/mail"
	"net/smtp"
	"net/textproto"
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
	SMTPTimeout     = 15 * time.Second
	ResetLinkBase   string
	ResetTokenTTL   = time.Hour
	ResetRateWindow = time.Minute
	ResetRateLimit  = 5
	TVLoginTTL      = 10 * time.Minute

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
		`INSERT INTO users (username, email, password_hash, email_verified) VALUES (?, ?, ?, 0)`,
		email, email, string(hash),
	)
	if err != nil {
		writeError(w, http.StatusConflict, "email already exists")
		return
	}

	id, err := res.LastInsertId()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create user")
		return
	}

	cleanupExpiredVerificationTokens()

	code, codeHash, err := newVerificationCode(id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to generate verification code")
		return
	}

	if _, err := database.DB.Exec(
		`INSERT INTO email_verification_tokens (user_id, token_hash, expires_at) VALUES (?, ?, ?)`,
		id, codeHash, time.Now().UTC().Add(ResetTokenTTL),
	); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create verification code")
		return
	}

	go func(emailAddress, verifyCode string) {
		if err := sendVerificationEmail(emailAddress, verifyCode); err != nil {
			log.Printf("failed to send verification email to %s: %v", emailAddress, err)
		}
	}(email, code)

	writeJSON(w, http.StatusCreated, map[string]string{"message": "verification code sent"})
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

	id, hash, storedEmail, storedUsername, emailVerified, found := lookupUserByIdentifier(req.Email)
	if !found {
		writeError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}
	if !emailVerified {
		writeError(w, http.StatusForbidden, "email not verified")
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

func StartTVLogin(w http.ResponseWriter, r *http.Request) {
	cleanupExpiredTVLoginSessions()

	deviceCode, deviceCodeHash, err := newTVDeviceCode()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to generate device code")
		return
	}

	userCode, userCodeHash, err := newTVUserCode(deviceCode)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to generate user code")
		return
	}

	expiresAt := time.Now().UTC().Add(TVLoginTTL)
	if _, err := database.DB.Exec(
		`INSERT INTO tv_login_sessions (device_code_hash, user_code_hash, expires_at) VALUES (?, ?, ?)`,
		deviceCodeHash, userCodeHash, expiresAt,
	); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create login session")
		return
	}

	writeJSON(w, http.StatusCreated, map[string]any{
		"device_code":           deviceCode,
		"user_code":             userCode,
		"expires_at":            expiresAt.Format(time.RFC3339),
		"poll_interval_seconds": 3,
	})
}

func ApproveTVLogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceCode string `json:"device_code"`
		UserCode   string `json:"user_code"`
		Email      string `json:"email"`
		Password   string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "device_code, user_code, email and password required")
		return
	}

	deviceCode := strings.TrimSpace(req.DeviceCode)
	userCode := strings.TrimSpace(req.UserCode)
	if deviceCode == "" || userCode == "" || strings.TrimSpace(req.Email) == "" || req.Password == "" {
		writeError(w, http.StatusBadRequest, "device_code, user_code, email and password required")
		return
	}

	deviceCodeHash := hashTVDeviceCode(deviceCode)
	userCodeHash := hashTVUserCode(deviceCode, userCode)

	var sessionID int64
	var storedUserCodeHash string
	var approvedAt sql.NullTime
	err := database.DB.QueryRow(`
		SELECT id, user_code_hash, approved_at
		FROM tv_login_sessions
		WHERE device_code_hash = ?
		  AND claimed_at IS NULL
		  AND expires_at > CURRENT_TIMESTAMP
		LIMIT 1
	`, deviceCodeHash).Scan(&sessionID, &storedUserCodeHash, &approvedAt)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid or expired tv login session")
		return
	}

	if storedUserCodeHash != userCodeHash {
		writeError(w, http.StatusUnauthorized, "invalid tv code")
		return
	}
	if approvedAt.Valid {
		writeJSON(w, http.StatusOK, map[string]string{"message": "tv login already approved"})
		return
	}

	id, hash, storedEmail, storedUsername, emailVerified, found := lookupUserByIdentifier(req.Email)
	if !found || bcrypt.CompareHashAndPassword([]byte(hash), []byte(req.Password)) != nil {
		writeError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}
	if !emailVerified {
		writeError(w, http.StatusForbidden, "email not verified")
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

	result, err := database.DB.Exec(`
		UPDATE tv_login_sessions
		SET approved_at = CURRENT_TIMESTAMP,
		    approved_user_id = ?,
		    approved_token = ?,
		    approved_username = ?,
		    approved_email = ?
		WHERE id = ?
		  AND approved_at IS NULL
		  AND claimed_at IS NULL
	`, id, token, identity, emailValue, sessionID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to approve tv login")
		return
	}

	rows, _ := result.RowsAffected()
	if rows == 0 {
		writeError(w, http.StatusConflict, "tv login session no longer valid")
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"message": "tv login approved"})
}

func PollTVLogin(w http.ResponseWriter, r *http.Request) {
	deviceCode := strings.TrimSpace(r.URL.Query().Get("device_code"))
	if deviceCode == "" {
		writeError(w, http.StatusBadRequest, "device_code required")
		return
	}

	deviceCodeHash := hashTVDeviceCode(deviceCode)

	var sessionID int64
	var approvedAt sql.NullTime
	var claimedAt sql.NullTime
	var expiresAt time.Time
	var token sql.NullString
	var userID sql.NullInt64
	var username sql.NullString
	var email sql.NullString
	err := database.DB.QueryRow(`
		SELECT id, approved_at, claimed_at, expires_at, approved_token, approved_user_id, approved_username, approved_email
		FROM tv_login_sessions
		WHERE device_code_hash = ?
		LIMIT 1
	`, deviceCodeHash).Scan(&sessionID, &approvedAt, &claimedAt, &expiresAt, &token, &userID, &username, &email)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid or expired tv login session")
		return
	}

	if claimedAt.Valid {
		writeError(w, http.StatusGone, "tv login session already used")
		return
	}
	if expiresAt.Before(time.Now().UTC()) {
		writeError(w, http.StatusGone, "tv login session expired")
		return
	}
	if !approvedAt.Valid {
		writeJSON(w, http.StatusOK, map[string]any{
			"status":     "pending",
			"expires_at": expiresAt.Format(time.RFC3339),
		})
		return
	}

	result, err := database.DB.Exec(`
		UPDATE tv_login_sessions
		SET claimed_at = CURRENT_TIMESTAMP
		WHERE id = ?
		  AND claimed_at IS NULL
	`, sessionID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to complete tv login")
		return
	}

	rows, _ := result.RowsAffected()
	if rows == 0 {
		writeError(w, http.StatusGone, "tv login session already used")
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status": "approved",
		"auth": map[string]any{
			"token":    token.String,
			"user_id":  userID.Int64,
			"username": username.String,
			"email":    email.String,
		},
	})
}

// lookupUserByIdentifier finds a user by email (primary) or username (legacy fallback).
// Returns (id, passwordHash, email, username, emailVerified, found).
func lookupUserByIdentifier(identifier string) (int64, string, sql.NullString, string, bool, bool) {
	identifier = strings.TrimSpace(identifier)
	var id int64
	var hash string
	var storedEmail sql.NullString
	var storedUsername string
	var emailVerifiedInt int

	// Try email lookup first.
	email, emailErr := normalizeEmail(identifier)
	if emailErr == nil {
		err := database.DB.QueryRow(
			`SELECT id, email, username, password_hash, email_verified FROM users WHERE lower(email) = lower(?)`, email,
		).Scan(&id, &storedEmail, &storedUsername, &hash, &emailVerifiedInt)
		if err == nil {
			return id, hash, storedEmail, storedUsername, emailVerifiedInt != 0, true
		}
		if err != sql.ErrNoRows {
			return 0, "", sql.NullString{}, "", false, false
		}
	}

	// Fallback to username for legacy accounts.
	err := database.DB.QueryRow(
		`SELECT id, email, username, password_hash, email_verified FROM users WHERE username = ?`, identifier,
	).Scan(&id, &storedEmail, &storedUsername, &hash, &emailVerifiedInt)
	if err != nil {
		return 0, "", sql.NullString{}, "", false, false
	}
	return id, hash, storedEmail, storedUsername, emailVerifiedInt != 0, true
}

func VerifyEmail(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email string `json:"email"`
		Code  string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.Email) == "" || strings.TrimSpace(req.Code) == "" {
		writeError(w, http.StatusBadRequest, "email and code required")
		return
	}

	email, err := normalizeEmail(req.Email)
	if err != nil {
		writeError(w, http.StatusBadRequest, "email and code required")
		return
	}

	userID, err := lookupUserIDByEmail(email)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid or expired code")
		return
	}

	tx, err := database.DB.Begin()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to verify email")
		return
	}
	defer tx.Rollback()

	tokenHash := hashVerificationCode(userID, req.Code)
	var tokenID int64
	err = tx.QueryRow(`
		SELECT id
		FROM email_verification_tokens
		WHERE user_id = ?
		  AND token_hash = ?
		  AND used_at IS NULL
		  AND expires_at > CURRENT_TIMESTAMP
	`, userID, tokenHash).Scan(&tokenID)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid or expired code")
		return
	}

	if _, err := tx.Exec(`UPDATE users SET email_verified = 1 WHERE id = ?`, userID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to verify email")
		return
	}

	if _, err := tx.Exec(`UPDATE email_verification_tokens SET used_at = CURRENT_TIMESTAMP WHERE id = ?`, tokenID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to verify email")
		return
	}

	if err := tx.Commit(); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to verify email")
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"message": "email verified"})
}

func ResendVerification(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email string `json:"email"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.Email) == "" {
		writeError(w, http.StatusBadRequest, "email required")
		return
	}

	email, err := normalizeEmail(req.Email)
	if err != nil {
		writeError(w, http.StatusBadRequest, "email required")
		return
	}

	if !allowResetFor(email, clientIP(r)) {
		writeError(w, http.StatusTooManyRequests, "too many requests, try again later")
		return
	}

	cleanupExpiredVerificationTokens()

	var userID int64
	var emailVerifiedInt int
	err = database.DB.QueryRow(`SELECT id, email_verified FROM users WHERE lower(email) = lower(?)`, email).Scan(&userID, &emailVerifiedInt)
	if err != nil {
		if err != sql.ErrNoRows {
			log.Printf("resend verification lookup failed: %v", err)
		}
		writeJSON(w, http.StatusOK, map[string]string{"message": "If the email exists, a verification code has been sent."})
		return
	}

	if emailVerifiedInt != 0 {
		log.Printf("resend verification requested for already verified email: %s", email)
	}

	code, codeHash, err := newVerificationCode(userID)
	if err != nil {
		log.Printf("failed to generate verification code: %v", err)
		writeJSON(w, http.StatusOK, map[string]string{"message": "If the email exists, a verification code has been sent."})
		return
	}

	if _, err := database.DB.Exec(`DELETE FROM email_verification_tokens WHERE user_id = ? AND used_at IS NULL`, userID); err != nil {
		log.Printf("failed to clear previous verification codes: %v", err)
	}

	if _, err := database.DB.Exec(
		`INSERT INTO email_verification_tokens (user_id, token_hash, expires_at) VALUES (?, ?, ?)`,
		userID, codeHash, time.Now().UTC().Add(ResetTokenTTL),
	); err != nil {
		log.Printf("failed to store verification code: %v", err)
		writeJSON(w, http.StatusOK, map[string]string{"message": "If the email exists, a verification code has been sent."})
		return
	}

	log.Printf("queued verification resend email to %s", email)

	go func(emailAddress, verificationCode string) {
		if err := sendVerificationEmail(emailAddress, verificationCode); err != nil {
			log.Printf("failed to send verification email to %s: %v", emailAddress, err)
		}
	}(email, code)

	writeJSON(w, http.StatusOK, map[string]string{"message": "If the email exists, a verification code has been sent."})
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
		writeJSON(w, http.StatusOK, map[string]string{"message": "If the email exists, a reset code has been sent."})
		return
	}

	rawCode, tokenHash, err := newResetCode(userID)
	if err != nil {
		log.Printf("failed to generate reset code: %v", err)
		writeJSON(w, http.StatusOK, map[string]string{"message": "If the email exists, a reset code has been sent."})
		return
	}

	if _, err := database.DB.Exec(`DELETE FROM password_reset_tokens WHERE user_id = ? AND used_at IS NULL`, userID); err != nil {
		log.Printf("failed to clear previous reset codes: %v", err)
	}

	expiresAt := time.Now().UTC().Add(ResetTokenTTL)
	if _, err := database.DB.Exec(
		`INSERT INTO password_reset_tokens (user_id, token_hash, expires_at) VALUES (?, ?, ?)`,
		userID, tokenHash, expiresAt,
	); err != nil {
		log.Printf("failed to store reset token: %v", err)
		writeJSON(w, http.StatusOK, map[string]string{"message": "If the email exists, a reset code has been sent."})
		return
	}

	go func(emailAddress, code string) {
		if err := sendPasswordResetEmail(emailAddress, code); err != nil {
			log.Printf("failed to send reset email to %s: %v", emailAddress, err)
		}
	}(email, rawCode)

	writeJSON(w, http.StatusOK, map[string]string{"message": "If the email exists, a reset code has been sent."})
}

func VerifyResetToken(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email string `json:"email"`
		Code  string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.Email) == "" || strings.TrimSpace(req.Code) == "" {
		writeError(w, http.StatusBadRequest, "email and code required")
		return
	}

	email, err := normalizeEmail(req.Email)
	if err != nil {
		writeError(w, http.StatusBadRequest, "email and code required")
		return
	}

	userID, err := lookupUserIDByEmail(email)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid or expired code")
		return
	}

	valid, err := isResetCodeValid(userID, req.Code)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid or expired code")
		return
	}

	writeJSON(w, http.StatusOK, map[string]bool{"valid": valid})
}

func ResetPassword(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email       string `json:"email"`
		Code        string `json:"code"`
		NewPassword string `json:"new_password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.Email) == "" || strings.TrimSpace(req.Code) == "" || req.NewPassword == "" {
		writeError(w, http.StatusBadRequest, "email, code and new_password required")
		return
	}

	email, err := normalizeEmail(req.Email)
	if err != nil {
		writeError(w, http.StatusBadRequest, "email, code and new_password required")
		return
	}

	if len(req.NewPassword) < 8 {
		writeError(w, http.StatusBadRequest, "password must be at least 8 characters")
		return
	}

	userID, err := lookupUserIDByEmail(email)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid or expired code")
		return
	}

	tx, err := database.DB.Begin()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to reset password")
		return
	}
	defer tx.Rollback()

	tokenHash := hashResetCode(userID, req.Code)
	var tokenID int64
	err = tx.QueryRow(`
		SELECT id
		FROM password_reset_tokens
		WHERE user_id = ?
		  AND token_hash = ?
		  AND used_at IS NULL
		  AND expires_at > CURRENT_TIMESTAMP
	`, userID, tokenHash).Scan(&tokenID)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid or expired code")
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

func newResetCode(userID int64) (string, string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(10000))
	if err != nil {
		return "", "", err
	}
	code := fmt.Sprintf("%04d", n.Int64())
	return code, hashResetCode(userID, code), nil
}

func newVerificationCode(userID int64) (string, string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(10000))
	if err != nil {
		return "", "", err
	}
	code := fmt.Sprintf("%04d", n.Int64())
	return code, hashVerificationCode(userID, code), nil
}

func newTVDeviceCode() (string, string, error) {
	raw := make([]byte, 24)
	if _, err := rand.Read(raw); err != nil {
		return "", "", err
	}
	code := hex.EncodeToString(raw)
	return code, hashTVDeviceCode(code), nil
}

func newTVUserCode(deviceCode string) (string, string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		return "", "", err
	}
	code := fmt.Sprintf("%06d", n.Int64())
	return code, hashTVUserCode(deviceCode, code), nil
}

func hashResetCode(userID int64, code string) string {
	input := fmt.Sprintf("%d:%s", userID, strings.TrimSpace(code))
	s := sha256.Sum256([]byte(input))
	return hex.EncodeToString(s[:])
}

func hashVerificationCode(userID int64, code string) string {
	input := fmt.Sprintf("verify:%d:%s", userID, strings.TrimSpace(code))
	s := sha256.Sum256([]byte(input))
	return hex.EncodeToString(s[:])
}

func hashTVDeviceCode(code string) string {
	input := "tv-device:" + strings.TrimSpace(code)
	s := sha256.Sum256([]byte(input))
	return hex.EncodeToString(s[:])
}

func hashTVUserCode(deviceCode, userCode string) string {
	input := fmt.Sprintf("tv-user:%s:%s", strings.TrimSpace(deviceCode), strings.TrimSpace(userCode))
	s := sha256.Sum256([]byte(input))
	return hex.EncodeToString(s[:])
}

func isResetCodeValid(userID int64, code string) (bool, error) {
	tokenHash := hashResetCode(userID, code)
	var id int64
	err := database.DB.QueryRow(`
		SELECT id
		FROM password_reset_tokens
		WHERE user_id = ?
		  AND token_hash = ?
		  AND used_at IS NULL
		  AND expires_at > CURRENT_TIMESTAMP
		LIMIT 1
	`, userID, tokenHash).Scan(&id)
	if err != nil {
		if err == sql.ErrNoRows {
			return false, err
		}
		return false, err
	}
	return id > 0, nil
}

func lookupUserIDByEmail(email string) (int64, error) {
	var userID int64
	err := database.DB.QueryRow(`SELECT id FROM users WHERE lower(email) = lower(?)`, email).Scan(&userID)
	if err != nil {
		return 0, err
	}
	return userID, nil
}

func cleanupExpiredVerificationTokens() {
	if _, err := database.DB.Exec(`DELETE FROM email_verification_tokens WHERE used_at IS NOT NULL OR expires_at <= CURRENT_TIMESTAMP`); err != nil {
		log.Printf("failed to cleanup verification tokens: %v", err)
	}
}

func cleanupExpiredResetTokens() {
	if _, err := database.DB.Exec(`DELETE FROM password_reset_tokens WHERE used_at IS NOT NULL OR expires_at <= CURRENT_TIMESTAMP`); err != nil {
		log.Printf("failed to cleanup reset tokens: %v", err)
	}
}

func cleanupExpiredTVLoginSessions() {
	if _, err := database.DB.Exec(`DELETE FROM tv_login_sessions WHERE claimed_at IS NOT NULL OR expires_at <= CURRENT_TIMESTAMP`); err != nil {
		log.Printf("failed to cleanup tv login sessions: %v", err)
	}
}

func sendPasswordResetEmail(toEmail, rawCode string) error {
	if SMTPHost == "" || SMTPPort == "" || SMTPFrom == "" {
		log.Printf("SMTP not configured, reset code for %s: %s", toEmail, rawCode)
		return nil
	}

	body := "Your IPTV Player reset code is: " + rawCode + "\n\n"
	body += fmt.Sprintf("Enter this 4-digit code in the app. The code expires in %d minutes.\n", int(ResetTokenTTL.Minutes()))
	body += "If you did not request this, you can ignore this email.\n"

	msg := buildSMTPMessage(toEmail, "IPTV Player password reset", body)

	addr := net.JoinHostPort(SMTPHost, SMTPPort)

	if SMTPPort == "465" {
		return sendMailImplicitTLS(addr, toEmail, msg)
	}

	return sendMailWithTimeout(addr, toEmail, msg, true)
}

func sendVerificationEmail(toEmail, rawCode string) error {
	if SMTPHost == "" || SMTPPort == "" || SMTPFrom == "" {
		log.Printf("SMTP not configured, verification code for %s: %s", toEmail, rawCode)
		return nil
	}

	body := "Your IPTV Player verification code is: " + rawCode + "\n\n"
	body += "Enter this 4-digit code in the app to activate your account.\n"
	body += fmt.Sprintf("The code expires in %d minutes.\n", int(ResetTokenTTL.Minutes()))
	body += "If you did not create this account, you can ignore this email.\n"

	msg := buildSMTPMessage(toEmail, "IPTV Player email verification", body)

	addr := net.JoinHostPort(SMTPHost, SMTPPort)
	if SMTPPort == "465" {
		return sendMailImplicitTLS(addr, toEmail, msg)
	}
	return sendMailWithTimeout(addr, toEmail, msg, true)
}

func sendMailImplicitTLS(addr, toEmail string, msg []byte) error {
	timeout := SMTPTimeout
	if timeout <= 0 {
		timeout = 15 * time.Second
	}

	dialer := &net.Dialer{Timeout: timeout}
	conn, err := tls.DialWithDialer(dialer, "tcp", addr, &tls.Config{
		ServerName: SMTPHost,
		MinVersion: tls.VersionTLS12,
	})
	if err != nil {
		return fmt.Errorf("dial implicit TLS failed: %w", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(timeout))

	client, err := smtp.NewClient(conn, SMTPHost)
	if err != nil {
		return fmt.Errorf("smtp client failed: %w", err)
	}
	defer client.Close()

	return sendWithClient(client, toEmail, msg)
}

func sendMailWithTimeout(addr, toEmail string, msg []byte, useStartTLS bool) error {
	timeout := SMTPTimeout
	if timeout <= 0 {
		timeout = 15 * time.Second
	}

	dialer := &net.Dialer{Timeout: timeout}
	conn, err := dialer.Dial("tcp", addr)
	if err != nil {
		return fmt.Errorf("dial failed: %w", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(timeout))

	client, err := smtp.NewClient(conn, SMTPHost)
	if err != nil {
		return fmt.Errorf("smtp client failed: %w", err)
	}
	defer client.Close()

	if useStartTLS {
		if ok, _ := client.Extension("STARTTLS"); ok {
			if err := client.StartTLS(&tls.Config{ServerName: SMTPHost, MinVersion: tls.VersionTLS12}); err != nil {
				return fmt.Errorf("starttls failed: %w", err)
			}
		}
	}

	return sendWithClient(client, toEmail, msg)
}

func sendWithClient(client *smtp.Client, toEmail string, msg []byte) error {
	if SMTPUsername != "" {
		auth := smtp.PlainAuth("", SMTPUsername, SMTPPassword, SMTPHost)
		if err := client.Auth(auth); err != nil {
			return fmt.Errorf("auth failed: %w", err)
		}
	}

	if err := client.Mail(SMTPFrom); err != nil {
		return fmt.Errorf("mail from failed: %w", err)
	}
	if err := client.Rcpt(toEmail); err != nil {
		return fmt.Errorf("rcpt failed: %w", err)
	}

	w, err := client.Data()
	if err != nil {
		return fmt.Errorf("data failed: %w", err)
	}
	if _, err := w.Write(msg); err != nil {
		_ = w.Close()
		return fmt.Errorf("write failed: %w", err)
	}
	if err := w.Close(); err != nil {
		return fmt.Errorf("close data failed: %w", err)
	}

	if err := client.Quit(); err != nil {
		return fmt.Errorf("quit failed: %w", err)
	}

	return nil
}

func buildSMTPMessage(toEmail, subject, body string) []byte {
	header := textproto.MIMEHeader{}
	header.Set("From", SMTPFrom)
	header.Set("To", toEmail)
	header.Set("Subject", subject)
	header.Set("Date", time.Now().UTC().Format(time.RFC1123Z))
	header.Set("Message-ID", fmt.Sprintf("<%d.%d@%s>", time.Now().UnixNano(), time.Now().Unix()%100000, SMTPHost))
	header.Set("MIME-Version", "1.0")
	header.Set("Content-Type", "text/plain; charset=UTF-8")
	header.Set("Content-Transfer-Encoding", "8bit")

	var b strings.Builder
	for k, values := range header {
		for _, v := range values {
			b.WriteString(k)
			b.WriteString(": ")
			b.WriteString(v)
			b.WriteString("\r\n")
		}
	}
	b.WriteString("\r\n")
	b.WriteString(body)

	return []byte(b.String())
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
