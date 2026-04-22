package providers

import (
	"context"
	"encoding/xml"
	"fmt"
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
			logoURL := ""
			candidateLogoURL := fmt.Sprintf("%s/picon/%s.png", base, piconName(svcRef))
			if exists, ok := piconExistsCache[candidateLogoURL]; ok {
				if exists {
					logoURL = candidateLogoURL
				}
			} else {
				exists = urlReachable(piconClient, candidateLogoURL)
				piconExistsCache[candidateLogoURL] = exists
				if exists {
					logoURL = candidateLogoURL
				}
			}

			channels = append(channels, models.Channel{
				PlaylistID: playlistID,
				StreamID:   svcRef,
				Name:       svcName,
				GroupName:  name,
				StreamURL:  streamURL,
				LogoURL:    logoURL,
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

func piconName(sRef string) string {
	s := strings.ToLower(sRef)
	s = strings.ReplaceAll(s, ":", "_")
	s = strings.TrimRight(s, "_")
	return s
}

func urlReachable(client *http.Client, rawURL string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()

	headReq, err := http.NewRequestWithContext(ctx, http.MethodHead, rawURL, nil)
	if err == nil {
		if resp, reqErr := client.Do(headReq); reqErr == nil {
			resp.Body.Close()
			if resp.StatusCode >= 200 && resp.StatusCode < 300 {
				return true
			}
			if resp.StatusCode != http.StatusMethodNotAllowed && resp.StatusCode != http.StatusNotImplemented {
				return false
			}
		}
	}

	ctxGet, cancelGet := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancelGet()

	getReq, err := http.NewRequestWithContext(ctxGet, http.MethodGet, rawURL, nil)
	if err != nil {
		return false
	}
	getReq.Header.Set("Range", "bytes=0-0")

	resp, err := client.Do(getReq)
	if err != nil {
		return false
	}
	defer resp.Body.Close()

	return resp.StatusCode >= 200 && resp.StatusCode < 300
}
