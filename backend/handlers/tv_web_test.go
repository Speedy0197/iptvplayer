package handlers

import (
	"encoding/json"
	"github.com/go-chi/chi/v5"
	"net/http"
	"strings"
	"testing"
)

func TestTVCanonicalPageServedWithPrivateNavigation(t *testing.T) {
	r := chi.NewRouter()
	TVWebRoutes(r)
	w := requestTV(t, r, "GET", "/tv/activate", nil, "")
	if w.Code != 200 || !strings.Contains(w.Header().Get("Content-Type"), "text/html") {
		t.Fatalf("canonical page: %d %s", w.Code, w.Header().Get("Content-Type"))
	}
	if w.Header().Get("Referrer-Policy") != "no-referrer" || w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("approval navigation must not leak referrers or be cached")
	}
}

func TestTVAppleAssociationMatchesKnownApp(t *testing.T) {
	r := chi.NewRouter()
	TVWebRoutes(r)
	w := requestTV(t, r, "GET", "/.well-known/apple-app-site-association", nil, "")
	var result struct {
		Applinks struct {
			Details []struct {
				AppID string `json:"appID"`
				Paths []string
			}
		}
	}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if w.Code != 200 || len(result.Applinks.Details) != 1 || result.Applinks.Details[0].AppID != "FR7M4F46TP.com.flo.streampilot" || result.Applinks.Details[0].Paths[0] != "/tv/activate" {
		t.Fatalf("Apple association missing approved app: %s", w.Body)
	}
}

func TestTVAndroidAssociationNeedsVerifiedFingerprint(t *testing.T) {
	r := chi.NewRouter()
	TVWebRoutes(r)
	original := AndroidAppSHA256
	t.Cleanup(func() { AndroidAppSHA256 = original })
	for _, value := range []string{"", "unverified-placeholder"} {
		AndroidAppSHA256 = value
		w := requestTV(t, r, "GET", "/.well-known/assetlinks.json", nil, "")
		if w.Code != http.StatusServiceUnavailable {
			t.Fatalf("missing/unverified Android fingerprint must not advertise association: %d", w.Code)
		}
	}
	AndroidAppSHA256 = strings.TrimSuffix(strings.Repeat("AB:", 32), ":")
	w := requestTV(t, r, "GET", "/.well-known/assetlinks.json", nil, "")
	var result []struct {
		Target struct {
			PackageName string   `json:"package_name"`
			Fingerprint []string `json:"sha256_cert_fingerprints"`
		}
	}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if w.Code != 200 || len(result) != 1 || result[0].Target.PackageName != "com.flo.streampilot" || len(result[0].Target.Fingerprint) != 1 || result[0].Target.Fingerprint[0] != AndroidAppSHA256 {
		t.Fatalf("Android association: %s", w.Body)
	}
}
