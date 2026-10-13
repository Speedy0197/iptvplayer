package handlers

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"github.com/go-chi/chi/v5"
	"golang.org/x/crypto/bcrypt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/flodev/iptvplayer/database"
	"github.com/flodev/iptvplayer/middleware"
)

func pairingDB(t *testing.T) {
	t.Helper()
	database.Init(filepath.Join(t.TempDir(), "pairing.db"))
	t.Cleanup(func() { database.DB.Close() })
	middleware.JWTSecret = []byte("synthetic-test-key")
	tvLookupLimiter = pairingRateLimiter{entries: map[string]rateEntry{}}
}

func requestTV(t *testing.T, handler http.Handler, method, target string, body any, token string) *httptest.ResponseRecorder {
	t.Helper()
	var data bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&data).Encode(body); err != nil {
			t.Fatal(err)
		}
	}
	r := httptest.NewRequest(method, target, &data)
	r.RemoteAddr = "192.0.2.1:1234"
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	return w
}

func startTV(t *testing.T) map[string]any {
	t.Helper()
	w := requestTV(t, http.HandlerFunc(StartTVLogin), "POST", "/auth/tv/start", nil, "")
	if w.Code != http.StatusCreated {
		t.Fatalf("start: %d %s", w.Code, w.Body)
	}
	var value map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &value); err != nil {
		t.Fatal(err)
	}
	return value
}

// Missing approval secrets would force the TV polling secret into QR links.
func TestTVStartSeparatesApprovalAndPollingSecrets(t *testing.T) {
	pairingDB(t)
	v := startTV(t)
	approval, ok := v["pairing_token"].(string)
	if !ok || approval == "" {
		t.Fatal("start must return a separate pairing_token")
	}
	if approval == v["device_code"] {
		t.Fatal("approval must not expose device polling secret")
	}
	if v["poll_interval_seconds"] != float64(3) {
		t.Fatal("missing polling interval")
	}
	w := requestTV(t, http.HandlerFunc(PollTVLogin), "GET", "/auth/tv/poll?device_code="+approval, nil, "")
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("pairing secret can poll: %d", w.Code)
	}
}

// Equal JWTs issued during one second would copy the phone session into the TV.
func TestTVTokensAreIndependent(t *testing.T) {
	pairingDB(t)
	first, err := generateToken(1)
	if err != nil {
		t.Fatal(err)
	}
	second, err := generateToken(1)
	if err != nil {
		t.Fatal(err)
	}
	if first == second {
		t.Fatal("separately issued account/TV tokens must be distinct")
	}
}

func pairingRouter() http.Handler {
	r := chi.NewRouter()
	TVRoutes(r)
	return r
}

func accountTV(t *testing.T, email string, verified bool) (int64, string) {
	t.Helper()
	hash, err := bcrypt.GenerateFromPassword([]byte("test-password"), bcrypt.MinCost)
	if err != nil {
		t.Fatal(err)
	}
	result, err := database.DB.Exec(`INSERT INTO users(username,email,password_hash,email_verified) VALUES(?,?,?,?)`, email, email, string(hash), verified)
	if err != nil {
		t.Fatal(err)
	}
	id, err := result.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	token, err := generateToken(id)
	if err != nil {
		t.Fatal(err)
	}
	return id, token
}

func sessionTV(t *testing.T, router http.Handler, start map[string]any) *httptest.ResponseRecorder {
	return requestTV(t, router, "GET", "/auth/tv/session?pairing_token="+stringTV(start, "pairing_token"), nil, "")
}

func stringTV(value map[string]any, key string) string { s, _ := value[key].(string); return s }

func TestTVSessionNeverRevealsPollingOrAccountSecrets(t *testing.T) {
	pairingDB(t)
	router := pairingRouter()
	start := startTV(t)
	w := sessionTV(t, router, start)
	if w.Code != 200 {
		t.Fatalf("session: want 200, got %d", w.Code)
	}
	var v map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &v); err != nil {
		t.Fatal(err)
	}
	if v["user_code"] != start["user_code"] || v["status"] != "pending" || v["device_name"] != "StreamPilot TV" {
		t.Fatalf("session contract: %v", v)
	}
	for _, secret := range []string{"device_code", "auth", "token", "pairing_token"} {
		if _, found := v[secret]; found {
			t.Fatalf("session reveals %s", secret)
		}
	}
	if w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("session must not be cached")
	}
}

func TestTVApprovalRequiresVerifiedBearerAccount(t *testing.T) {
	pairingDB(t)
	router := pairingRouter()
	start := startTV(t)
	_, unverified := accountTV(t, "unverified@example.test", false)
	body := map[string]any{"pairing_token": start["pairing_token"]}
	for _, tc := range []struct {
		name, token string
		want        int
	}{{"anonymous", "", 401}, {"unverified", unverified, 403}} {
		t.Run(tc.name, func(t *testing.T) {
			w := requestTV(t, router, "POST", "/auth/tv/approve-session", body, tc.token)
			if w.Code != tc.want {
				t.Fatalf("approval want %d, got %d", tc.want, w.Code)
			}
		})
	}
	_, verified := accountTV(t, "verified@example.test", true)
	w := requestTV(t, router, "POST", "/auth/tv/approve-session?token="+verified, body, "")
	if w.Code != 401 {
		t.Fatalf("query token accepted: %d", w.Code)
	}
}

func TestTVApprovalIssuesIndependentTokenAndClaimsOnce(t *testing.T) {
	pairingDB(t)
	router := pairingRouter()
	id, phoneToken := accountTV(t, "phone@example.test", true)
	start := startTV(t)
	body := map[string]any{"pairing_token": start["pairing_token"]}
	w := requestTV(t, router, "POST", "/auth/tv/approve-session", body, phoneToken)
	if w.Code != 200 {
		t.Fatalf("approve: %d %s", w.Code, w.Body)
	}
	if strings.Contains(w.Body.String(), phoneToken) {
		t.Fatal("approval response contains account token")
	}
	w = sessionTV(t, router, start)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"approved"`) {
		t.Fatalf("approved session: %d %s", w.Code, w.Body)
	}
	poll := "/auth/tv/poll?device_code=" + stringTV(start, "device_code")
	w = requestTV(t, router, "GET", poll, nil, "")
	if w.Code != 200 {
		t.Fatalf("poll: %d %s", w.Code, w.Body)
	}
	var payload struct {
		Status string
		Auth   struct {
			Token  string
			UserID int64 `json:"user_id"`
		}
	}
	if err := json.Unmarshal(w.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Status != "approved" || payload.Auth.UserID != id || payload.Auth.Token == "" || payload.Auth.Token == phoneToken {
		t.Fatal("TV must receive its own token for approved account")
	}
	for _, action := range []struct {
		method, target string
		body           any
		token          string
	}{{"GET", poll, nil, ""}, {"POST", "/auth/tv/approve-session", body, phoneToken}, {"GET", "/auth/tv/session?pairing_token=" + stringTV(start, "pairing_token"), nil, ""}} {
		w = requestTV(t, router, action.method, action.target, action.body, action.token)
		if w.Code != 410 {
			t.Fatalf("claimed session want 410, got %d", w.Code)
		}
	}
}

func TestTVDeclineAndExpiryCannotApprove(t *testing.T) {
	pairingDB(t)
	router := pairingRouter()
	_, token := accountTV(t, "owner@example.test", true)
	for _, state := range []string{"declined", "expired"} {
		t.Run(state, func(t *testing.T) {
			start := startTV(t)
			body := map[string]any{"pairing_token": start["pairing_token"]}
			if state == "declined" {
				w := requestTV(t, router, "POST", "/auth/tv/decline-session", body, token)
				if w.Code != 200 {
					t.Fatalf("decline: %d", w.Code)
				}
				w = sessionTV(t, router, start)
				if w.Code != 200 || !strings.Contains(w.Body.String(), `"declined"`) {
					t.Fatalf("declined session: %d %s", w.Code, w.Body)
				}
			} else {
				if _, err := database.DB.Exec(`UPDATE tv_login_sessions SET expires_at=? WHERE device_code_hash=?`, time.Now().UTC().Add(-time.Minute), hashTVDeviceCode(stringTV(start, "device_code"))); err != nil {
					t.Fatal(err)
				}
			}
			w := requestTV(t, router, "POST", "/auth/tv/approve-session", body, token)
			if w.Code != 410 && w.Code != 409 {
				t.Fatalf("inactive approval: %d", w.Code)
			}
			w = requestTV(t, router, "GET", "/auth/tv/poll?device_code="+stringTV(start, "device_code"), nil, "")
			if state == "expired" && w.Code != 410 {
				t.Fatalf("expired poll: %d", w.Code)
			}
			if state == "declined" && (w.Code != 200 || !strings.Contains(w.Body.String(), `"declined"`) || strings.Contains(w.Body.String(), `"auth"`)) {
				t.Fatalf("declined poll: %d %s", w.Code, w.Body)
			}
		})
	}
}

func TestTVConcurrentApprovalsCannotReassign(t *testing.T) {
	pairingDB(t)
	router := pairingRouter()
	start := startTV(t)
	firstID, first := accountTV(t, "first@example.test", true)
	secondID, second := accountTV(t, "second@example.test", true)
	ready := make(chan struct{})
	results := make(chan struct {
		id   int64
		code int
	}, 2)
	for _, account := range []struct {
		id    int64
		token string
	}{{firstID, first}, {secondID, second}} {
		go func(id int64, token string) {
			<-ready
			w := requestTV(t, router, "POST", "/auth/tv/approve-session", map[string]any{"pairing_token": start["pairing_token"]}, token)
			results <- struct {
				id   int64
				code int
			}{id, w.Code}
		}(account.id, account.token)
	}
	close(ready)
	approvedID := int64(0)
	for i := 0; i < 2; i++ {
		result := <-results
		if result.code == 200 {
			if approvedID != 0 {
				t.Fatal("both accounts approved")
			}
			approvedID = result.id
		} else if result.code != 409 {
			t.Fatalf("losing approval: %d", result.code)
		}
	}
	w := requestTV(t, router, "GET", "/auth/tv/poll?device_code="+stringTV(start, "device_code"), nil, "")
	var v struct {
		Auth struct {
			UserID int64 `json:"user_id"`
		}
	}
	json.Unmarshal(w.Body.Bytes(), &v)
	if w.Code != 200 || approvedID == 0 || v.Auth.UserID != approvedID {
		t.Fatal("poll account differs from approval winner")
	}
}

func TestTVCodeLookupIsBoundedAndRateLimited(t *testing.T) {
	pairingDB(t)
	router := pairingRouter()
	start := startTV(t)
	w := requestTV(t, router, "POST", "/auth/tv/lookup", map[string]any{"user_code": start["user_code"]}, "")
	var v map[string]any
	json.Unmarshal(w.Body.Bytes(), &v)
	if w.Code != 200 || v["pairing_token"] != start["pairing_token"] {
		t.Fatalf("lookup: %d %s", w.Code, w.Body)
	}
	for i := 0; i < 12; i++ {
		w = requestTV(t, router, "POST", "/auth/tv/lookup", map[string]any{"user_code": "not-a-code"}, "")
	}
	if w.Code != 429 {
		t.Fatalf("lookup must limit repeated attempts: %d", w.Code)
	}
}

func TestLegacyTVPasswordApprovalStillWorks(t *testing.T) {
	pairingDB(t)
	router := pairingRouter()
	start := startTV(t)
	id, _ := accountTV(t, "legacy@example.test", true)
	w := requestTV(t, router, "POST", "/auth/tv/approve", map[string]any{"device_code": start["device_code"], "user_code": start["user_code"], "email": "legacy@example.test", "password": "test-password"}, "")
	if w.Code != 200 {
		t.Fatalf("legacy approval: %d %s", w.Code, w.Body)
	}
	w = requestTV(t, router, "GET", "/auth/tv/poll?device_code="+stringTV(start, "device_code"), nil, "")
	var v struct {
		Auth struct {
			UserID int64 `json:"user_id"`
		}
	}
	json.Unmarshal(w.Body.Bytes(), &v)
	if w.Code != 200 || v.Auth.UserID != id {
		t.Fatalf("legacy poll: %d %s", w.Code, w.Body)
	}
}

func TestTVConcurrentPollsOnlyOneReceivesToken(t *testing.T) {
	pairingDB(t)
	router := pairingRouter()
	start := startTV(t)
	_, token := accountTV(t, "poll@example.test", true)
	w := requestTV(t, router, "POST", "/auth/tv/approve-session", map[string]any{"pairing_token": start["pairing_token"]}, token)
	if w.Code != 200 {
		t.Fatalf("approve: %d", w.Code)
	}
	ready := make(chan struct{})
	results := make(chan *httptest.ResponseRecorder, 2)
	for i := 0; i < 2; i++ {
		go func() {
			<-ready
			results <- requestTV(t, router, "GET", "/auth/tv/poll?device_code="+stringTV(start, "device_code"), nil, "")
		}()
	}
	close(ready)
	success, gone := 0, 0
	for i := 0; i < 2; i++ {
		w := <-results
		switch w.Code {
		case 200:
			success++
			if !strings.Contains(w.Body.String(), `"token"`) {
				t.Fatal("successful claim lacks token")
			}
		case 410:
			gone++
			if strings.Contains(w.Body.String(), `"token"`) {
				t.Fatal("repeat claim reveals token")
			}
		default:
			t.Fatalf("poll: %d %s", w.Code, w.Body)
		}
	}
	if success != 1 || gone != 1 {
		t.Fatalf("claim winners=%d rejected=%d", success, gone)
	}
	var retained sql.NullString
	if err := database.DB.QueryRow(`SELECT approved_token FROM tv_login_sessions`).Scan(&retained); err != nil {
		t.Fatal(err)
	}
	if retained.Valid {
		t.Fatal("claimed token must be removed from short-lived session")
	}
}

func TestTVApprovalCannotReassignOrBeDeclinedAfterApproval(t *testing.T) {
	pairingDB(t)
	router := pairingRouter()
	start := startTV(t)
	_, first := accountTV(t, "owner@example.test", true)
	_, second := accountTV(t, "other@example.test", true)
	body := map[string]any{"pairing_token": start["pairing_token"]}
	w := requestTV(t, router, "POST", "/auth/tv/approve-session", body, first)
	if w.Code != 200 {
		t.Fatalf("approve: %d", w.Code)
	}
	for _, action := range []struct{ path, token string }{{"/auth/tv/approve-session", second}, {"/auth/tv/decline-session", second}, {"/auth/tv/approve-session", first}} {
		w = requestTV(t, router, "POST", action.path, body, action.token)
		if w.Code != 409 {
			t.Fatalf("already-approved mutation: %d", w.Code)
		}
	}
}

func TestTVLookupRejectsExpiredCodeAndPollingSecret(t *testing.T) {
	pairingDB(t)
	router := pairingRouter()
	start := startTV(t)
	w := requestTV(t, router, "POST", "/auth/tv/lookup", map[string]any{"user_code": start["device_code"]}, "")
	if w.Code != 400 {
		t.Fatalf("polling secret used as lookup code: %d", w.Code)
	}
	_, err := database.DB.Exec(`UPDATE tv_login_sessions SET expires_at=?`, time.Now().UTC().Add(-time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	w = requestTV(t, router, "POST", "/auth/tv/lookup", map[string]any{"user_code": start["user_code"]}, "")
	if w.Code != 404 {
		t.Fatalf("expired code lookup: %d", w.Code)
	}
}

func TestTVDeclineRequiresVerifiedBearerAccount(t *testing.T) {
	pairingDB(t)
	router := pairingRouter()
	start := startTV(t)
	_, unverified := accountTV(t, "unverified-decline@example.test", false)
	for _, account := range []struct {
		token string
		want  int
	}{{"", 401}, {unverified, 403}} {
		w := requestTV(t, router, "POST", "/auth/tv/decline-session", map[string]any{"pairing_token": start["pairing_token"]}, account.token)
		if w.Code != account.want {
			t.Fatalf("decline permission: want %d got %d", account.want, w.Code)
		}
	}
}

func TestTVLookupIgnoresSpoofedForwardedIP(t *testing.T) {
	pairingDB(t)
	router := pairingRouter()
	for i := 0; i < 6; i++ {
		r := httptest.NewRequest("POST", "/auth/tv/lookup", strings.NewReader(`{"user_code":"invalid"}`))
		r.RemoteAddr = "192.0.2.90:1234"
		r.Header.Set("X-Forwarded-For", fmt.Sprintf("192.0.2.%d", i))
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		if i == 5 && w.Code != 429 {
			t.Fatalf("spoofed forwarded IP bypassed limiter: %d", w.Code)
		}
	}
}

func TestLegacyTVSessionWithoutNewPairingFieldsStillWorks(t *testing.T) {
	pairingDB(t)
	router := pairingRouter()
	id, _ := accountTV(t, "old-installed-tv@example.test", true)
	device := "legacy-device-code"
	code := "654321"
	_, err := database.DB.Exec(`INSERT INTO tv_login_sessions(device_code_hash,user_code_hash,expires_at) VALUES(?,?,?)`, hashTVDeviceCode(device), hashTVUserCode(device, code), time.Now().UTC().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	w := requestTV(t, router, "POST", "/auth/tv/approve", map[string]string{"device_code": device, "user_code": code, "email": "old-installed-tv@example.test", "password": "test-password"}, "")
	if w.Code != 200 {
		t.Fatalf("old session approval: %d %s", w.Code, w.Body)
	}
	w = requestTV(t, router, "GET", "/auth/tv/poll?device_code="+device, nil, "")
	var payload struct {
		Auth struct {
			UserID int64 `json:"user_id"`
		}
	}
	json.Unmarshal(w.Body.Bytes(), &payload)
	if w.Code != 200 || payload.Auth.UserID != id {
		t.Fatalf("old session poll: %d %s", w.Code, w.Body)
	}
}
