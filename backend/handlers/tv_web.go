package handlers

import (
	"crypto/sha256"
	_ "embed"
	"encoding/base64"
	"net/http"
	"regexp"
	"strings"

	"github.com/go-chi/chi/v5"
)

//go:embed assets/tv-activate.html
var tvActivationPage string

// AndroidAppSHA256 must come from the actual release-signing certificate.
// Comma-separated fingerprints allow certificate rotation with overlap.
var AndroidAppSHA256 string
var certificateFingerprint = regexp.MustCompile(`^(?:[0-9A-F]{2}:){31}[0-9A-F]{2}$`)

func TVWebRoutes(r chi.Router) {
	r.Get("/tv/activate", TVActivationPage)
	r.Get("/.well-known/apple-app-site-association", AppleAppAssociation)
	r.Get("/.well-known/assetlinks.json", AndroidAppAssociation)
}

func TVActivationPage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	// A static hash permits only the bundled script; remote scripts cannot run.
	script := strings.Split(strings.Split(tvActivationPage, "<script>")[1], "</script>")[0]
	hash := sha256.Sum256([]byte(script))
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'sha256-"+base64.StdEncoding.EncodeToString(hash[:])+"'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	w.Write([]byte(tvActivationPage))
}

func AppleAppAssociation(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-Content-Type-Options", "nosniff")
	writeJSON(w, 200, map[string]any{"applinks": map[string]any{"apps": []string{}, "details": []any{map[string]any{"appID": "FR7M4F46TP.com.flo.streampilot", "paths": []string{"/tv/activate"}}}}})
}

func AndroidAppAssociation(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-Content-Type-Options", "nosniff")
	fingerprints := []string{}
	for _, configured := range strings.Split(AndroidAppSHA256, ",") {
		fingerprint := strings.ToUpper(strings.TrimSpace(configured))
		if !certificateFingerprint.MatchString(fingerprint) {
			w.Header().Set("Cache-Control", "no-store")
			writeError(w, 503, "Android app association is not configured")
			return
		}
		fingerprints = append(fingerprints, fingerprint)
	}
	writeJSON(w, 200, []any{map[string]any{"relation": []string{"delegate_permission/common.handle_all_urls"}, "target": map[string]any{"namespace": "android_app", "package_name": "com.flo.streampilot", "sha256_cert_fingerprints": fingerprints}}})
}
