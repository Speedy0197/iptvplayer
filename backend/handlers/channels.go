package handlers

import (
	"bufio"
	"context"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/flodev/iptvplayer/database"
	"github.com/flodev/iptvplayer/middleware"
	"github.com/flodev/iptvplayer/models"
	"github.com/go-chi/chi/v5"
)

func ownsPlaylist(userID, playlistID int64) (models.Playlist, bool) {
	var p models.Playlist
	err := database.DB.QueryRow(
		`SELECT id, user_id, name, type, m3u_url, m3u_content, xtream_server, xtream_username, xtream_password,
		        vuplus_ip, vuplus_port, epg_url, last_refreshed, created_at
		 FROM playlists WHERE id = ? AND user_id = ?`, playlistID, userID,
	).Scan(&p.ID, &p.UserID, &p.Name, &p.Type, &p.M3UURL, &p.M3UContent,
		&p.XtreamServer, &p.XtreamUsername, &p.XtreamPassword,
		&p.VuplusIP, &p.VuplusPort,
		&p.EpgURL, &p.LastRefreshed, &p.CreatedAt)
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
		if err := rows.Scan(&c.ID, &c.PlaylistID, &c.StreamID, &c.Name,
			&c.GroupName, &c.StreamURL, &c.LogoURL, &c.EpgChannelID,
			&c.SortOrder, &c.IsFavorite); err != nil {
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
			channels, err = parseM3U(strings.NewReader(*p.M3UContent), playlistID)
		} else if p.M3UURL != nil && *p.M3UURL != "" {
			channels, err = fetchM3U(*p.M3UURL, playlistID)
		} else {
			writeError(w, http.StatusBadRequest, "playlist has no URL or content")
			return
		}
	case "xtream":
		channels, err = fetchXtream(p, playlistID)
	case "vuplus":
		channels, err = fetchVuplus(p, playlistID)
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

// fetchM3U downloads and parses an M3U playlist
func fetchM3U(url string, playlistID int64) ([]models.Channel, error) {
	resp, err := http.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	return parseM3U(resp.Body, playlistID)
}

func parseM3U(r io.Reader, playlistID int64) ([]models.Channel, error) {
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
			// Parse attributes
			current.Name = extractM3UAttr(line, "tvg-name")
			if current.Name == "" {
				// Fall back to the display name after the last comma
				if idx := strings.LastIndex(line, ","); idx >= 0 {
					current.Name = strings.TrimSpace(line[idx+1:])
				}
			}
			current.LogoURL = extractM3UAttr(line, "tvg-logo")
			current.EpgChannelID = extractM3UAttr(line, "tvg-id")
			current.GroupName = extractM3UAttr(line, "group-title")
			if current.GroupName == "" {
				current.GroupName = "Uncategorized"
			}
			continue
		}

		if current != nil && !strings.HasPrefix(line, "#") {
			current.StreamURL = line
			// Use URL as stream_id fallback
			if current.StreamID == "" {
				current.StreamID = line
			}
			channels = append(channels, *current)
			current = nil
		}
	}

	return channels, scanner.Err()
}

func extractM3UAttr(line, attr string) string {
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

// Xtream Code API response types
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

func fetchXtream(p models.Playlist, playlistID int64) ([]models.Channel, error) {
	server := *p.XtreamServer
	user := *p.XtreamUsername
	pass := *p.XtreamPassword

	// Fetch categories
	catURL := fmt.Sprintf("%s/player_api.php?username=%s&password=%s&action=get_live_categories", server, user, pass)
	catResp, err := http.Get(catURL)
	if err != nil {
		return nil, fmt.Errorf("categories fetch: %w", err)
	}
	defer catResp.Body.Close()

	var categories []xtreamCategory
	if err := json.NewDecoder(catResp.Body).Decode(&categories); err != nil {
		return nil, fmt.Errorf("categories decode: %w", err)
	}

	catMap := make(map[string]string)
	for _, c := range categories {
		catMap[c.CategoryID] = c.CategoryName
	}

	// Fetch streams
	streamURL := fmt.Sprintf("%s/player_api.php?username=%s&password=%s&action=get_live_streams", server, user, pass)
	streamResp, err := http.Get(streamURL)
	if err != nil {
		return nil, fmt.Errorf("streams fetch: %w", err)
	}
	defer streamResp.Body.Close()

	var streams []xtreamStream
	if err := json.NewDecoder(streamResp.Body).Decode(&streams); err != nil {
		return nil, fmt.Errorf("streams decode: %w", err)
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

	// Store EPG URL for Xtream playlists
	epgURL := fmt.Sprintf("%s/xmltv.php?username=%s&password=%s", server, user, pass)
	database.DB.Exec(`UPDATE playlists SET epg_url = ? WHERE id = ?`, epgURL, playlistID)

	return channels, nil
}

// OpenWebif XML structures
type e2ServiceList struct {
	Services []e2Service `xml:"e2service"`
}

type e2Service struct {
	Reference string `xml:"e2servicereference"`
	Name      string `xml:"e2servicename"`
}

// fetchVuplus fetches channels from a VU+/Enigma2 box via the OpenWebif HTTP API.
// It loads /web/getservices to get bouquets (groups), then fetches each bouquet's
// channel list. Stream URLs are constructed as http://<ip>:8001/<sRef>.
func fetchVuplus(p models.Playlist, playlistID int64) ([]models.Channel, error) {
	ip := *p.VuplusIP
	port := "80"
	if p.VuplusPort != nil && *p.VuplusPort != "" {
		port = *p.VuplusPort
	}
	base := fmt.Sprintf("http://%s:%s", ip, port)

	// Fetch top-level bouquet list
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
		// Only process bouquet-type references (1:7:)
		if !strings.HasPrefix(ref, "1:7:") {
			continue
		}

		svcURL := fmt.Sprintf("%s/web/getservices?sRef=%s", base, url.QueryEscape(ref))
		services, err := fetchE2Services(svcURL)
		if err != nil {
			continue // skip on error, try next bouquet
		}

		for _, svc := range services {
			svcRef := strings.TrimSpace(svc.Reference)
			svcName := strings.TrimSpace(svc.Name)
			if svcRef == "" || svcName == "" {
				continue
			}
			// Skip nested bouquets and markers; only include regular services (1:0:)
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

// piconName converts an Enigma2 service reference to the OpenWebif picon filename.
// e.g. "1:0:1:283D:411:1:C00000:0:0:0:" → "1_0_1_283d_411_1_c00000_0_0_0"
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
