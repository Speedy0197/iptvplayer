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
	const debugPiconLimit = 30
	debuggedPicon := 0
	piconProbedOk := 0
	piconProbedFail := 0

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

			canonicalSvcRef := normalizeVuplusServiceRef(svcRef)
			streamURL := fmt.Sprintf("http://%s:8001/%s", ip, svcRef)
			logoURL := vuplusGetPiconURL(base, svcRef)
			if logoURL == "" {
				logoURL = vuplusGetPiconURL(base, canonicalSvcRef)
			}

			attemptDebug := "not_probed"
			if debuggedPicon < debugPiconLimit {
				if ok, status := urlReachable(piconClient, logoURL); ok {
					attemptDebug = fmt.Sprintf("probe:%s", status)
					piconProbedOk++
				} else {
					attemptDebug = fmt.Sprintf("probe:%s", status)
					piconProbedFail++
				}
			}
			if debuggedPicon < debugPiconLimit {
				log.Printf("[vuplus][picon] playlist=%d channel=%q sRef=%q canonical=%q selected=%q attempts=%s",
					playlistID,
					svcName,
					svcRef,
					canonicalSvcRef,
					logoURL,
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

	log.Printf("[vuplus][picon] playlist=%d summary channels=%d assigned_logo=%d debugged=%d probe_ok=%d probe_fail=%d",
		playlistID,
		len(channels),
		len(channels),
		debuggedPicon,
		piconProbedOk,
		piconProbedFail,
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

// normalizeVuplusServiceRef keeps only the canonical Enigma2 service fields.
// Many IPTV-backed services append URL/name segments after field 10, but picons
// are keyed by the first 10 fields only.
func normalizeVuplusServiceRef(sRef string) string {
	trimmed := strings.TrimSpace(sRef)
	if trimmed == "" {
		return ""
	}

	parts := strings.Split(trimmed, ":")
	if len(parts) >= 10 {
		return strings.Join(parts[:10], ":") + ":"
	}

	return trimmed
}

func vuplusGetPiconURL(base, sRef string) string {
	trimmedRef := strings.TrimSpace(sRef)
	if trimmedRef == "" {
		return ""
	}

	return fmt.Sprintf("%s/web/getpicon?sRef=%s", base, url.QueryEscape(trimmedRef))
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
