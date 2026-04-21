package handlers

import (
	"database/sql"
	"encoding/json"
	"fmt"
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
	for rows.Next() {
		var c models.Channel
		if err := rows.Scan(&c.ID, &c.PlaylistID, &c.StreamID, &c.Name,
			&c.GroupName, &c.StreamURL, &c.LogoURL, &c.EpgChannelID,
			&c.SortOrder, &c.IsFavorite); err != nil {
			continue
		}
		channels = append(channels, c)
	}
	writeJSON(w, http.StatusOK, channels)
}

func AddFavoriteChannel(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r)

	var req struct {
		ChannelID int64 `json:"channel_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ChannelID == 0 {
		writeError(w, http.StatusBadRequest, "channel_id required")
		return
	}

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
		if isSQLiteBusyErr(err) {
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
	channelID, err := strconv.ParseInt(chi.URLParam(r, "channel_id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid channel_id")
		return
	}

	if _, err := database.DB.Exec(
		`DELETE FROM favorite_channels WHERE user_id = ? AND channel_id = ?`,
		userID, channelID,
	); err != nil {
		if isSQLiteBusyErr(err) {
			writeError(w, http.StatusServiceUnavailable, "database busy, please retry")
			return
		}
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("db error: %v", err))
		return
	}
	w.WriteHeader(http.StatusNoContent)
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
