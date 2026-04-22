package providers

import (
	"bufio"
	"io"
	"net/http"
	"strings"

	"github.com/flodev/iptvplayer/models"
)

func FetchM3U(url string, playlistID int64) ([]models.Channel, error) {
	resp, err := http.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	return ParseM3U(resp.Body, playlistID)
}

func ParseM3U(r io.Reader, playlistID int64) ([]models.Channel, error) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)

	var channels []models.Channel
	var current *models.Channel

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || line == "#EXTM3U" {
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

	return channels, scanner.Err()
}

func extractAttr(line, attr string) string {
	key := attr + `="`
	idx := strings.Index(line, key)
	if idx < 0 {
		return ""
	}
	start := idx + len(key)
	end := strings.Index(line[start:], `"`)
	if end < 0 {
		return ""
	}
	return line[start : start+end]
}
