package providers

import (
	"bufio"
	"io"
	"net/http"
	"strings"

	"github.com/flodev/iptvplayer/models"
)

func FetchM3U(url string, playlistID int64) ([]models.Channel, error) {
	channels, _, err := FetchM3UWithEPG(url, playlistID)
	return channels, err
}

func FetchM3UWithEPG(url string, playlistID int64) ([]models.Channel, string, error) {
	resp, err := http.Get(url)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()
	return ParseM3UWithEPG(resp.Body, playlistID)
}

func ParseM3U(r io.Reader, playlistID int64) ([]models.Channel, error) {
	channels, _, err := ParseM3UWithEPG(r, playlistID)
	return channels, err
}

func ParseM3UWithEPG(r io.Reader, playlistID int64) ([]models.Channel, string, error) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)

	var channels []models.Channel
	var current *models.Channel
	epgURL := ""

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		if strings.HasPrefix(line, "#EXTM3U") {
			if epgURL == "" {
				epgURL = extractFirstAttr(line, "url-tvg", "x-tvg-url", "tvg-url")
			}
			continue
		}

		if strings.HasPrefix(line, "#EXTINF:") {
			current = &models.Channel{PlaylistID: playlistID}
			current.Name = extractAttr(line, "tvg-name")
			if current.Name == "" {
				if idx := strings.LastIndex(line, ","); idx >= 0 {
					current.Name = strings.TrimSpace(line[idx+1:])
				}
			}
			current.LogoURL = extractAttr(line, "tvg-logo")
			current.EpgChannelID = extractAttr(line, "tvg-id")
			current.GroupName = extractAttr(line, "group-title")
			if current.GroupName == "" {
				current.GroupName = "Uncategorized"
			}
			continue
		}

		if current != nil && !strings.HasPrefix(line, "#") {
			current.StreamURL = line
			if current.StreamID == "" {
				current.StreamID = line
			}
			channels = append(channels, *current)
			current = nil
		}
	}

	return channels, epgURL, scanner.Err()
}

func extractFirstAttr(line string, attrs ...string) string {
	for _, attr := range attrs {
		if value := extractAttr(line, attr); value != "" {
			return value
		}
	}
	return ""
}

func extractAttr(line, attr string) string {
	key := attr + `="`
	idx := strings.Index(line, key)
	if idx < 0 {
		// Handle unquoted attributes, e.g. x-tvg-url=http://example.com/epg.xml
		plainKey := attr + "="
		plainIdx := strings.Index(line, plainKey)
		if plainIdx < 0 {
			return ""
		}
		start := plainIdx + len(plainKey)
		end := strings.IndexAny(line[start:], " \t")
		if end < 0 {
			return strings.TrimSpace(line[start:])
		}
		return strings.TrimSpace(line[start : start+end])
	}
	start := idx + len(key)
	end := strings.Index(line[start:], `"`)
	if end < 0 {
		return ""
	}
	return strings.TrimSpace(line[start : start+end])
}
