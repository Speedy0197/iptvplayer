package providers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"

	"github.com/flodev/iptvplayer/models"
)

type xtreamCategory struct {
	CategoryID   string `json:"category_id"`
	CategoryName string `json:"category_name"`
}

type xtreamStream struct {
	Num          int    `json:"num"`
	Name         string `json:"name"`
	StreamID     int    `json:"stream_id"`
	StreamIcon   string `json:"stream_icon"`
	EPGChannelID string `json:"epg_channel_id"`
	CategoryID   string `json:"category_id"`
	DirectSource string `json:"direct_source"`
}

// FetchXtream fetches live channels from an Xtream Codes API.
// Returns channels, the EPG URL for the playlist, and any error.
func FetchXtream(p models.Playlist, playlistID int64) ([]models.Channel, string, error) {
	server := *p.XtreamServer
	user := *p.XtreamUsername
	pass := *p.XtreamPassword

	catURL := fmt.Sprintf("%s/player_api.php?username=%s&password=%s&action=get_live_categories", server, user, pass)
	catResp, err := http.Get(catURL)
	if err != nil {
		return nil, "", fmt.Errorf("categories fetch: %w", err)
	}
	defer catResp.Body.Close()

	var categories []xtreamCategory
	if err := json.NewDecoder(catResp.Body).Decode(&categories); err != nil {
		return nil, "", fmt.Errorf("categories decode: %w", err)
	}

	catMap := make(map[string]string)
	for _, c := range categories {
		catMap[c.CategoryID] = c.CategoryName
	}

	streamURL := fmt.Sprintf("%s/player_api.php?username=%s&password=%s&action=get_live_streams", server, user, pass)
	streamResp, err := http.Get(streamURL)
	if err != nil {
		return nil, "", fmt.Errorf("streams fetch: %w", err)
	}
	defer streamResp.Body.Close()

	var streams []xtreamStream
	if err := json.NewDecoder(streamResp.Body).Decode(&streams); err != nil {
		return nil, "", fmt.Errorf("streams decode: %w", err)
	}

	var channels []models.Channel
	for _, s := range streams {
		groupName := catMap[s.CategoryID]
		if groupName == "" {
			groupName = "Uncategorized"
		}
		streamPlayURL := fmt.Sprintf("%s/live/%s/%s/%d.ts", server, user, pass, s.StreamID)
		channels = append(channels, models.Channel{
			PlaylistID:   playlistID,
			StreamID:     strconv.Itoa(s.StreamID),
			Name:         s.Name,
			GroupName:    groupName,
			StreamURL:    streamPlayURL,
			LogoURL:      s.StreamIcon,
			EpgChannelID: s.EPGChannelID,
		})
	}

	epgURL := fmt.Sprintf("%s/xmltv.php?username=%s&password=%s", server, user, pass)
	return channels, epgURL, nil
}
