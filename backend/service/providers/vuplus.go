package providers

import (
	"encoding/xml"
	"fmt"
	"net/http"
	"net/url"
	"strings"

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
