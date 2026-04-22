package handlers

import (
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/flodev/iptvplayer/database"
	"github.com/flodev/iptvplayer/middleware"
	"github.com/flodev/iptvplayer/models"
	"github.com/flodev/iptvplayer/service/providers"
	"github.com/go-chi/chi/v5"
)

func ownsPlaylist(userID, playlistID int64) (models.Playlist, bool) {
	p, err := database.GetPlaylistForUser(playlistID, userID)
	return p, err == nil
}

func ListGroups(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r)
	playlistID, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}

	if _, ok := ownsPlaylist(userID, playlistID); !ok {
		writeError(w, http.StatusNotFound, "playlist not found")
		return
	}

	rows, err := database.DB.Query(
		`SELECT c.group_name, COUNT(*) as cnt,
		        CASE WHEN fg.group_name IS NOT NULL THEN 1 ELSE 0 END as is_favorite
		 FROM channels c
		 LEFT JOIN favorite_groups fg ON fg.playlist_id = c.playlist_id
		   AND fg.group_name = c.group_name AND fg.user_id = ?
		 WHERE c.playlist_id = ?
		 GROUP BY c.group_name
		 ORDER BY c.group_name`, userID, playlistID,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "db error")
		return
	}
	defer rows.Close()

	groups := []models.Group{}
	for rows.Next() {
		var g models.Group
		g.PlaylistID = playlistID
		if err := rows.Scan(&g.Name, &g.ChannelCount, &g.IsFavorite); err != nil {
			continue
		}
		groups = append(groups, g)
	}
	writeJSON(w, http.StatusOK, groups)
}

func ListChannels(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r)
	playlistID, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}

	if _, ok := ownsPlaylist(userID, playlistID); !ok {
		writeError(w, http.StatusNotFound, "playlist not found")
		return
	}

	groupFilter := r.URL.Query().Get("group")
	search := r.URL.Query().Get("search")

	query := `SELECT c.id, c.playlist_id, c.stream_id, c.name, c.group_name,
	                 c.stream_url, c.logo_url, c.epg_channel_id, c.sort_order,
	                 CASE WHEN fc.channel_id IS NOT NULL THEN 1 ELSE 0 END as is_favorite
	          FROM channels c
	          LEFT JOIN favorite_channels fc ON fc.channel_id = c.id AND fc.user_id = ?
	          WHERE c.playlist_id = ?`
	args := []any{userID, playlistID}

	if groupFilter != "" {
		query += " AND c.group_name = ?"
		args = append(args, groupFilter)
	}
	if search != "" {
		query += " AND c.name LIKE ?"
		args = append(args, "%"+search+"%")
	}
	query += " ORDER BY c.sort_order, c.name"

	rows, err := database.DB.Query(query, args...)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "db error")
		return
	}
	defer rows.Close()

	channels := []models.Channel{}
	for rows.Next() {
		var c models.Channel
		if err := database.ScanChannel(rows, &c); err != nil {
			continue
		}
		channels = append(channels, c)
	}
	writeJSON(w, http.StatusOK, channels)
}

func RefreshPlaylist(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r)
	playlistID, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}

	p, ok := ownsPlaylist(userID, playlistID)
	if !ok {
		writeError(w, http.StatusNotFound, "playlist not found")
		return
	}

	var channels []models.Channel
	switch p.Type {
	case "m3u":
		if p.M3UContent != nil && *p.M3UContent != "" {
			channels, err = providers.ParseM3U(strings.NewReader(*p.M3UContent), playlistID)
		} else if p.M3UURL != nil && *p.M3UURL != "" {
			channels, err = providers.FetchM3U(*p.M3UURL, playlistID)
		} else {
			writeError(w, http.StatusBadRequest, "playlist has no URL or content")
			return
		}
	case "xtream":
		var epgURL string
		channels, epgURL, err = providers.FetchXtream(p, playlistID)
		if err == nil && epgURL != "" {
			database.DB.Exec(`UPDATE playlists SET epg_url = ? WHERE id = ?`, epgURL, playlistID)
		}
	case "vuplus":
		channels, err = providers.FetchVuplus(p, playlistID)
	}
	if err != nil {
		writeError(w, http.StatusBadGateway, fmt.Sprintf("fetch error: %v", err))
		return
	}

	if err := persistRefreshedChannels(playlistID, channels); err != nil {
		log.Printf("refresh playlist %d failed: %v", playlistID, err)
		if isSQLiteBusy(err) {
			writeError(w, http.StatusServiceUnavailable, "database busy, please retry")
			return
		}
		writeError(w, http.StatusInternalServerError, "db error")
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"count": len(channels)})
}

func persistRefreshedChannels(playlistID int64, channels []models.Channel) error {
	const maxAttempts = 3

	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		tx, err := database.DB.Begin()
		if err != nil {
			lastErr = err
			if isSQLiteBusy(err) && attempt < maxAttempts {
				time.Sleep(time.Duration(attempt) * 250 * time.Millisecond)
				continue
			}
			return err
		}

		if _, err := tx.Exec(`DELETE FROM channels WHERE playlist_id = ?`, playlistID); err != nil {
			lastErr = err
			if isSQLiteBusy(err) && attempt < maxAttempts {
				tx.Rollback()
				time.Sleep(time.Duration(attempt) * 250 * time.Millisecond)
				continue
			}
			return err
		}

		stmt, err := tx.Prepare(
			`INSERT INTO channels (playlist_id, stream_id, name, group_name, stream_url, logo_url, epg_channel_id, sort_order)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		)
		if err != nil {
			lastErr = err
			if isSQLiteBusy(err) && attempt < maxAttempts {
				tx.Rollback()
				time.Sleep(time.Duration(attempt) * 250 * time.Millisecond)
				continue
			}
			return err
		}

		insertFailed := false
		for i, c := range channels {
			if _, err := stmt.Exec(playlistID, c.StreamID, c.Name, c.GroupName,
				c.StreamURL, c.LogoURL, c.EpgChannelID, i); err != nil {
				lastErr = err
				insertFailed = true
				break
			}
		}
		stmt.Close()

		if insertFailed {
			if isSQLiteBusy(lastErr) && attempt < maxAttempts {
				tx.Rollback()
				time.Sleep(time.Duration(attempt) * 250 * time.Millisecond)
				continue
			}
			return lastErr
		}

		if _, err := tx.Exec(`UPDATE playlists SET last_refreshed = ? WHERE id = ?`, time.Now(), playlistID); err != nil {
			lastErr = err
			if isSQLiteBusy(err) && attempt < maxAttempts {
				tx.Rollback()
				time.Sleep(time.Duration(attempt) * 250 * time.Millisecond)
				continue
			}
			return err
		}

		if err := tx.Commit(); err != nil {
			lastErr = err
			if isSQLiteBusy(err) && attempt < maxAttempts {
				tx.Rollback()
				time.Sleep(time.Duration(attempt) * 250 * time.Millisecond)
				continue
			}
			tx.Rollback()
			return err
		}

		return nil
	}

	if lastErr != nil {
		log.Printf("refresh playlist %d failed after retries: %v", playlistID, lastErr)
	}
	return lastErr
}
