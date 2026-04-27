package handlers

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"net/http"
	"strconv"
	"strings"

	"github.com/flodev/iptvplayer/database"
	"github.com/flodev/iptvplayer/middleware"
	"github.com/flodev/iptvplayer/models"
	"github.com/go-chi/chi/v5"
)

// --- Favorite Channels ---

func ListFavoriteChannels(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r)

	rows, err := database.DB.Query(
		`SELECT c.id, c.playlist_id, c.stream_id, c.name, c.group_name,
		        c.stream_url, c.logo_url, c.epg_channel_id, c.sort_order, 1 as is_favorite
		 FROM channels c
		 JOIN favorite_channels fc ON fc.channel_id = c.id
		 WHERE fc.user_id = ?
		 ORDER BY fc.created_at DESC`, userID,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "db error")
		return
	}
	defer rows.Close()

	channels := []models.Channel{}
	seenKeys := map[string]struct{}{}
	for rows.Next() {
		var c models.Channel
		if err := database.ScanChannel(rows, &c); err != nil {
			continue
		}
		key := fmt.Sprintf("%d:%s", c.PlaylistID, strings.ToLower(strings.TrimSpace(c.StreamID)))
		seenKeys[key] = struct{}{}
		channels = append(channels, c)
	}

	sourceRows, err := database.DB.Query(
		`SELECT playlist_id, stream_id, name, group_name, stream_url, logo_url, epg_channel_id, sort_order
		 FROM favorite_channel_sources
		 WHERE user_id = ?
		 ORDER BY created_at DESC`, userID,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "db error")
		return
	}
	defer sourceRows.Close()

	for sourceRows.Next() {
		var c models.Channel
		if err := sourceRows.Scan(
			&c.PlaylistID,
			&c.StreamID,
			&c.Name,
			&c.GroupName,
			&c.StreamURL,
			&c.LogoURL,
			&c.EpgChannelID,
			&c.SortOrder,
		); err != nil {
			continue
		}

		if c.GroupName == "" {
			c.GroupName = "Uncategorized"
		}
		c.IsFavorite = true
		c.ID = stableFavoriteSourceID(c.PlaylistID, c.StreamID)

		key := fmt.Sprintf("%d:%s", c.PlaylistID, strings.ToLower(strings.TrimSpace(c.StreamID)))
		if _, exists := seenKeys[key]; exists {
			continue
		}
		seenKeys[key] = struct{}{}
		channels = append(channels, c)
	}

	writeJSON(w, http.StatusOK, channels)
}

func AddFavoriteChannel(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r)

	var req struct {
		ChannelID    int64  `json:"channel_id"`
		PlaylistID   int64  `json:"playlist_id"`
		StreamID     string `json:"stream_id"`
		Name         string `json:"name"`
		GroupName    string `json:"group_name"`
		StreamURL    string `json:"stream_url"`
		LogoURL      string `json:"logo_url"`
		EPGChannelID string `json:"epg_channel_id"`
		SortOrder    int    `json:"sort_order"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	if req.ChannelID > 0 {
		// Verify the channel belongs to one of the user's playlists
		var exists int
		if err := database.DB.QueryRow(
			`SELECT COUNT(*) FROM channels c
		 JOIN playlists p ON p.id = c.playlist_id
		 WHERE c.id = ? AND p.user_id = ?`, req.ChannelID, userID,
		).Scan(&exists); err != nil {
			writeError(w, http.StatusInternalServerError, fmt.Sprintf("db error: %v", err))
			return
		}
		if exists == 0 {
			writeError(w, http.StatusNotFound, "channel not found")
			return
		}

		if _, err := database.DB.Exec(
			`INSERT OR IGNORE INTO favorite_channels (user_id, channel_id) VALUES (?, ?)`,
			userID, req.ChannelID,
		); err != nil {
			if isSQLiteBusy(err) {
				writeError(w, http.StatusServiceUnavailable, "database busy, please retry")
				return
			}
			writeError(w, http.StatusInternalServerError, fmt.Sprintf("db error: %v", err))
			return
		}
		w.WriteHeader(http.StatusNoContent)
		return
	}

	req.StreamID = strings.TrimSpace(req.StreamID)
	if req.PlaylistID == 0 || req.StreamID == "" {
		writeError(w, http.StatusBadRequest, "channel_id or playlist_id+stream_id required")
		return
	}

	if _, ok := ownsPlaylist(userID, req.PlaylistID); !ok {
		writeError(w, http.StatusNotFound, "playlist not found")
		return
	}

	req.Name = strings.TrimSpace(req.Name)
	if req.Name == "" {
		req.Name = req.StreamID
	}
	req.GroupName = strings.TrimSpace(req.GroupName)
	if req.GroupName == "" {
		req.GroupName = "Uncategorized"
	}
	req.StreamURL = strings.TrimSpace(req.StreamURL)
	req.LogoURL = strings.TrimSpace(req.LogoURL)
	req.EPGChannelID = strings.TrimSpace(req.EPGChannelID)

	if _, err := database.DB.Exec(
		`INSERT OR IGNORE INTO favorite_channel_sources
		(user_id, playlist_id, stream_id, name, group_name, stream_url, logo_url, epg_channel_id, sort_order)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		userID,
		req.PlaylistID,
		req.StreamID,
		req.Name,
		req.GroupName,
		req.StreamURL,
		req.LogoURL,
		req.EPGChannelID,
		req.SortOrder,
	); err != nil {
		if isSQLiteBusy(err) {
			writeError(w, http.StatusServiceUnavailable, "database busy, please retry")
			return
		}
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("db error: %v", err))
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func RemoveFavoriteChannel(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r)

	if channelIDRaw := chi.URLParam(r, "channel_id"); strings.TrimSpace(channelIDRaw) != "" {
		channelID, err := strconv.ParseInt(channelIDRaw, 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid channel_id")
			return
		}

		if _, err := database.DB.Exec(
			`DELETE FROM favorite_channels WHERE user_id = ? AND channel_id = ?`,
			userID, channelID,
		); err != nil {
			if isSQLiteBusy(err) {
				writeError(w, http.StatusServiceUnavailable, "database busy, please retry")
				return
			}
			writeError(w, http.StatusInternalServerError, fmt.Sprintf("db error: %v", err))
			return
		}
		w.WriteHeader(http.StatusNoContent)
		return
	}

	playlistIDRaw := strings.TrimSpace(r.URL.Query().Get("playlist_id"))
	streamID := strings.TrimSpace(r.URL.Query().Get("stream_id"))
	if playlistIDRaw == "" || streamID == "" {
		writeError(w, http.StatusBadRequest, "channel_id or playlist_id+stream_id required")
		return
	}
	playlistID, err := strconv.ParseInt(playlistIDRaw, 10, 64)
	if err != nil || playlistID <= 0 {
		writeError(w, http.StatusBadRequest, "invalid playlist_id")
		return
	}

	if _, err := database.DB.Exec(
		`DELETE FROM favorite_channel_sources WHERE user_id = ? AND playlist_id = ? AND stream_id = ?`,
		userID, playlistID, streamID,
	); err != nil {
		if isSQLiteBusy(err) {
			writeError(w, http.StatusServiceUnavailable, "database busy, please retry")
			return
		}
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("db error: %v", err))
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

func stableFavoriteSourceID(playlistID int64, streamID string) int64 {
	h := fnv.New32a()
	_, _ = h.Write([]byte(fmt.Sprintf("%d:%s", playlistID, strings.ToLower(strings.TrimSpace(streamID)))))
	value := int64(h.Sum32())
	if value == 0 {
		value = 1
	}
	return -value
}

// --- Favorite Groups ---

func ListFavoriteGroups(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r)

	rows, err := database.DB.Query(
		`SELECT fg.playlist_id, fg.group_name, COUNT(c.id) as channel_count
		 FROM favorite_groups fg
		 LEFT JOIN channels c ON c.playlist_id = fg.playlist_id AND c.group_name = fg.group_name
		 WHERE fg.user_id = ?
		 GROUP BY fg.playlist_id, fg.group_name
		 ORDER BY fg.created_at DESC`, userID,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "db error")
		return
	}
	defer rows.Close()

	groups := []models.Group{}
	for rows.Next() {
		var g models.Group
		g.IsFavorite = true
		if err := rows.Scan(&g.PlaylistID, &g.Name, &g.ChannelCount); err != nil {
			continue
		}
		groups = append(groups, g)
	}
	writeJSON(w, http.StatusOK, groups)
}

func AddFavoriteGroup(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r)

	var req struct {
		PlaylistID int64  `json:"playlist_id"`
		GroupName  string `json:"group_name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.PlaylistID == 0 || req.GroupName == "" {
		writeError(w, http.StatusBadRequest, "playlist_id and group_name required")
		return
	}

	req.GroupName = strings.TrimSpace(req.GroupName)
	if req.GroupName == "" {
		writeError(w, http.StatusBadRequest, "group_name required")
		return
	}

	if _, ok := ownsPlaylist(userID, req.PlaylistID); !ok {
		writeError(w, http.StatusNotFound, "playlist not found")
		return
	}

	var canonicalGroupName string
	if err := database.DB.QueryRow(
		`SELECT group_name
		 FROM channels
		 WHERE playlist_id = ? AND TRIM(group_name) = TRIM(?) COLLATE NOCASE
		 LIMIT 1`,
		req.PlaylistID, req.GroupName,
	).Scan(&canonicalGroupName); err != nil {
		if err == sql.ErrNoRows {
			writeError(w, http.StatusNotFound, "group not found")
			return
		}
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("db error: %v", err))
		return
	}

	if _, err := database.DB.Exec(
		`INSERT OR IGNORE INTO favorite_groups (user_id, playlist_id, group_name) VALUES (?, ?, ?)`,
		userID, req.PlaylistID, canonicalGroupName,
	); err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("db error: %v", err))
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func RemoveFavoriteGroup(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r)
	playlistIDRaw := chi.URLParam(r, "playlist_id")
	if playlistIDRaw == "" {
		playlistIDRaw = r.URL.Query().Get("playlist_id")
	}
	playlistID, err := strconv.ParseInt(playlistIDRaw, 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid playlist_id")
		return
	}
	groupName := chi.URLParam(r, "group_name")
	if groupName == "" {
		groupName = r.URL.Query().Get("group_name")
	}
	groupName = strings.TrimSpace(groupName)
	if groupName == "" {
		writeError(w, http.StatusBadRequest, "group_name required")
		return
	}

	if _, err := database.DB.Exec(
		`DELETE FROM favorite_groups
		 WHERE user_id = ? AND playlist_id = ? AND TRIM(group_name) = TRIM(?) COLLATE NOCASE`,
		userID, playlistID, groupName,
	); err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("db error: %v", err))
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
