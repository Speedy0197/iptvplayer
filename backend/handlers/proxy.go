package handlers

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"
)

var hopHeaders = []string{
	"Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization",
	"Te", "Trailers", "Transfer-Encoding", "Upgrade",
}

func ProxyStream(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	reqID := fmt.Sprintf("%d", start.UnixNano())

	rawURL := r.URL.Query().Get("url")
	if rawURL == "" {
		writeError(w, http.StatusBadRequest, "url parameter required")
		return
	}

	log.Printf("[proxy %s] incoming url=%q range=%q ua=%q", reqID, rawURL, r.Header.Get("Range"), r.Header.Get("User-Agent"))

	parsed, err := url.ParseRequestURI(rawURL)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		writeError(w, http.StatusBadRequest, "invalid url")
		return
	}

	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, rawURL, nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to build request")
		return
	}

	for _, h := range []string{"Range", "User-Agent"} {
		if v := r.Header.Get(h); v != "" {
			req.Header.Set(h, v)
		}
	}

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		log.Printf("[proxy %s] upstream request failed: %v", reqID, err)
		writeError(w, http.StatusBadGateway, "upstream error: "+err.Error())
		return
	}
	defer resp.Body.Close()

	log.Printf("[proxy %s] upstream status=%d content-type=%q", reqID, resp.StatusCode, resp.Header.Get("Content-Type"))

	// Surface upstream errors as JSON so the player can display a useful message.
	if resp.StatusCode >= 400 {
		bodySnippet, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		log.Printf("[proxy %s] upstream error body: %q", reqID, strings.TrimSpace(string(bodySnippet)))
		writeError(w, resp.StatusCode, fmt.Sprintf("upstream returned %d %s", resp.StatusCode, http.StatusText(resp.StatusCode)))
		return
	}

	for k, vs := range resp.Header {
		if !isHopHeader(k) {
			for _, v := range vs {
				w.Header().Add(k, v)
			}
		}
	}
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Debug-Proxy-Request-ID", reqID)
	w.WriteHeader(resp.StatusCode)

	flusher, canFlush := w.(http.Flusher)
	buf := make([]byte, 32*1024)
	var totalBytes int64
	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			totalBytes += int64(n)
			if _, writeErr := w.Write(buf[:n]); writeErr != nil {
				log.Printf("[proxy %s] write error after %d bytes: %v", reqID, totalBytes, writeErr)
				return
			}
			if canFlush {
				flusher.Flush()
			}
		}
		if readErr != nil {
			if readErr != io.EOF {
				log.Printf("[proxy %s] read error after %d bytes: %v", reqID, totalBytes, readErr)
			} else {
				log.Printf("[proxy %s] stream ended bytes=%d duration=%s", reqID, totalBytes, time.Since(start).Round(time.Millisecond))
			}
			return
		}
	}
}

func isHopHeader(h string) bool {
	h = strings.ToLower(h)
	for _, hop := range hopHeaders {
		if strings.ToLower(hop) == h {
			return true
		}
	}
	return false
}
