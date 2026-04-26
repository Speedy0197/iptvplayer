package providers

import (
	"context"
	"encoding/xml"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/flodev/iptvplayer/models"
)

type e2ServiceList struct {
	Services []e2Service `xml:"e2service"`
}

type e2Service struct {
	Reference string `xml:"e2servicereference"`
	Name      string `xml:"e2servicename"`
}

// FetchVuplus fetches channels from a VU+/Enigma2 box via the OpenWebif HTTP API.
func FetchVuplus(p models.Playlist, playlistID int64) ([]models.Channel, error) {
	ip := *p.VuplusIP
	port := "80"
	if p.VuplusPort != nil && *p.VuplusPort != "" {
		port = *p.VuplusPort
	}
	base := fmt.Sprintf("http://%s:%s", ip, port)

	bouquets, err := fetchE2Services(base + "/web/getservices")
	if err != nil {
		return nil, fmt.Errorf("getservices: %w", err)
	}

	var channels []models.Channel
	sortOrder := 0
	piconClient := &http.Client{Timeout: 1500 * time.Millisecond}
	piconExistsCache := make(map[string]bool)
	const debugPiconLimit = 30
	debuggedPicon := 0
	piconFound := 0
	piconMissing := 0

	for _, bouquet := range bouquets {
		ref := strings.TrimSpace(bouquet.Reference)
		name := strings.TrimSpace(bouquet.Name)
		if ref == "" || name == "" {
			continue
		}
		if !strings.HasPrefix(ref, "1:7:") {
			continue
		}

		svcURL := fmt.Sprintf("%s/web/getservices?sRef=%s", base, url.QueryEscape(ref))
		services, err := fetchE2Services(svcURL)
		if err != nil {
			continue
		}

		for _, svc := range services {
			svcRef := strings.TrimSpace(svc.Reference)
			svcName := strings.TrimSpace(svc.Name)
			if svcRef == "" || svcName == "" {
				continue
			}
			if !strings.HasPrefix(svcRef, "1:0:") {
				continue
			}

			streamURL := fmt.Sprintf("http://%s:8001/%s", ip, svcRef)
			logoURL, usedCandidate, attemptDebug := resolveVuplusPiconURL(base, svcRef, piconClient, piconExistsCache)
			if logoURL == "" {
				piconMissing++
			} else {
				piconFound++
			}
			if debuggedPicon < debugPiconLimit {
				log.Printf("[vuplus][picon] playlist=%d channel=%q sRef=%q selected=%q used=%q attempts=%s",
					playlistID,
					svcName,
					svcRef,
					logoURL,
					usedCandidate,
					attemptDebug,
				)
				debuggedPicon++
			}

			channels = append(channels, models.Channel{
				PlaylistID: playlistID,
				StreamID:   svcRef,
				Name:       svcName,
				GroupName:  name,
				StreamURL:  streamURL,
				LogoURL:    logoURL,
				EpgChannelID: svcRef,
				SortOrder:  sortOrder,
			})
			sortOrder++
		}
	}

	log.Printf("[vuplus][picon] playlist=%d summary channels=%d with_logo=%d missing_logo=%d debugged=%d",
		playlistID,
		len(channels),
		piconFound,
		piconMissing,
		debuggedPicon,
	)

	return channels, nil
}

func fetchE2Services(rawURL string) ([]e2Service, error) {
	resp, err := http.Get(rawURL)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var list e2ServiceList
	if err := xml.NewDecoder(resp.Body).Decode(&list); err != nil {
		return nil, err
	}
	return list.Services, nil
}

func piconName(sRef string) string {
	s := sRef
	s = strings.ReplaceAll(s, ":", "_")
	s = strings.TrimRight(s, "_")
	return s
}

func vuplusPiconCandidates(base, sRef string) []string {
	trimmedRef := strings.TrimSpace(sRef)
	if trimmedRef == "" {
		return nil
	}

	underscoreName := piconName(trimmedRef)
	lowerUnderscoreName := strings.ToLower(underscoreName)
	escapedRef := url.PathEscape(trimmedRef)

	candidates := []string{
		fmt.Sprintf("%s/picon/%s.png", base, underscoreName),
	}

	if lowerUnderscoreName != underscoreName {
		candidates = append(candidates, fmt.Sprintf("%s/picon/%s.png", base, lowerUnderscoreName))
	}

	candidates = append(candidates,
		fmt.Sprintf("%s/picon/%s.png", base, escapedRef),
		fmt.Sprintf("%s/picon/%s", base, escapedRef),
	)

	return candidates
}

func resolveVuplusPiconURL(base, sRef string, client *http.Client, cache map[string]bool) (string, string, string) {
	candidates := vuplusPiconCandidates(base, sRef)
	if len(candidates) == 0 {
		return "", "", "no_candidates"
	}

	attempts := make([]string, 0, len(candidates))
	for _, candidate := range candidates {
		reachable, cacheState := cache[candidate]
		if cacheState {
			if reachable {
				attempts = append(attempts, fmt.Sprintf("cache-hit-ok:%s", candidate))
				return candidate, candidate, strings.Join(attempts, " | ")
			}
			attempts = append(attempts, fmt.Sprintf("cache-hit-miss:%s", candidate))
			continue
		}

		reachable, status := urlReachable(client, candidate)
		cache[candidate] = reachable
		attempts = append(attempts, fmt.Sprintf("probe:%s=>%s", status, candidate))
		if reachable {
			return candidate, candidate, strings.Join(attempts, " | ")
		}
	}

	return "", "", strings.Join(attempts, " | ")
}

func urlReachable(client *http.Client, rawURL string) (bool, string) {
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()

	headReq, err := http.NewRequestWithContext(ctx, http.MethodHead, rawURL, nil)
	if err == nil {
		if resp, reqErr := client.Do(headReq); reqErr == nil {
			resp.Body.Close()
			if resp.StatusCode >= 200 && resp.StatusCode < 300 {
				if isImageContentType(resp.Header.Get("Content-Type")) {
					return true, fmt.Sprintf("HEAD %d %s", resp.StatusCode, strings.TrimSpace(resp.Header.Get("Content-Type")))
				}
				return false, fmt.Sprintf("HEAD %d non-image %s", resp.StatusCode, strings.TrimSpace(resp.Header.Get("Content-Type")))
			}
			if resp.StatusCode != http.StatusMethodNotAllowed && resp.StatusCode != http.StatusNotImplemented {
				return false, fmt.Sprintf("HEAD %d", resp.StatusCode)
			}
		} else {
			return false, fmt.Sprintf("HEAD error: %v", reqErr)
		}
	} else {
		return false, fmt.Sprintf("HEAD request error: %v", err)
	}

	ctxGet, cancelGet := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancelGet()

	getReq, err := http.NewRequestWithContext(ctxGet, http.MethodGet, rawURL, nil)
	if err != nil {
		return false, fmt.Sprintf("GET request error: %v", err)
	}
	getReq.Header.Set("Range", "bytes=0-0")

	resp, err := client.Do(getReq)
	if err != nil {
		return false, fmt.Sprintf("GET error: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		if isImageContentType(resp.Header.Get("Content-Type")) {
			return true, fmt.Sprintf("GET %d %s", resp.StatusCode, strings.TrimSpace(resp.Header.Get("Content-Type")))
		}
		return false, fmt.Sprintf("GET %d non-image %s", resp.StatusCode, strings.TrimSpace(resp.Header.Get("Content-Type")))
	}

	return false, fmt.Sprintf("GET %d", resp.StatusCode)
}

func isImageContentType(contentType string) bool {
	trimmed := strings.ToLower(strings.TrimSpace(contentType))
	if trimmed == "" {
		return false
	}
	return strings.HasPrefix(trimmed, "image/")
}
