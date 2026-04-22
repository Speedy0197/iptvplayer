package handlers

import (
	"encoding/xml"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/flodev/iptvplayer/database"
	"github.com/flodev/iptvplayer/middleware"
	"github.com/flodev/iptvplayer/models"
	"github.com/go-chi/chi/v5"
)

const epgCacheTTL = 6 * time.Hour

// XMLTV structures
type xmltvTV struct {
	XMLName    xml.Name        `xml:"tv"`
	Programmes []xmltvProgram  `xml:"programme"`
}

type xmltvProgram struct {
	Start   string `xml:"start,attr"`
	Stop    string `xml:"stop,attr"`
	Channel string `xml:"channel,attr"`
	Title   struct {
		Value string `xml:",chardata"`
	} `xml:"title"`
	Desc struct {
		Value string `xml:",chardata"`
	} `xml:"desc"`
}

var xmltvLayouts = []string{
	"20060102150405 -0700",
	"20060102150405 +0000",
	"20060102150405",
}

func parseXMLTVTime(s string) (time.Time, error) {
	for _, layout := range xmltvLayouts {
		if t, err := time.Parse(layout, s); err == nil {
			return t, nil
		}
	}
	return time.Time{}, fmt.Errorf("cannot parse time: %s", s)
}

func GetEPG(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r)
	playlistID, err := strconv.ParseInt(chi.URLParam(r, "playlist_id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid playlist_id")
		return
	}
	channelEpgID := chi.URLParam(r, "channel_epg_id")

	if _, ok := ownsPlaylist(userID, playlistID); !ok {
		writeError(w, http.StatusNotFound, "playlist not found")
		return
	}

	// Refresh EPG if cache is stale
	var fetchedAt time.Time
	database.DB.QueryRow(
		`SELECT fetched_at FROM epg_fetch_log WHERE playlist_id = ?`, playlistID,
	).Scan(&fetchedAt)

	if time.Since(fetchedAt) > epgCacheTTL {
		refreshEPG(playlistID)
	}

	rows, err := database.DB.Query(
		`SELECT channel_epg_id, start_time, end_time, title, description
		 FROM epg_cache
		 WHERE playlist_id = ? AND channel_epg_id = ? AND end_time > ?
		 ORDER BY start_time ASC
		 LIMIT 48`,
		playlistID, channelEpgID, time.Now().Add(-time.Hour),
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "db error")
		return
	}
	defer rows.Close()

	entries := []models.EPGEntry{}
	for rows.Next() {
		var e models.EPGEntry
		if err := rows.Scan(&e.ChannelEpgID, &e.StartTime, &e.EndTime, &e.Title, &e.Description); err != nil {
			continue
		}
		entries = append(entries, e)
	}
	writeJSON(w, http.StatusOK, entries)
}

func refreshEPG(playlistID int64) {
	var epgURL string
	if err := database.DB.QueryRow(
		`SELECT COALESCE(epg_url, '') FROM playlists WHERE id = ?`, playlistID,
	).Scan(&epgURL); err != nil || epgURL == "" {
		return
	}

	resp, err := http.Get(epgURL)
	if err != nil {
		log.Printf("EPG fetch failed for playlist %d: %v", playlistID, err)
		return
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		log.Printf("EPG read failed for playlist %d: %v", playlistID, err)
		return
	}

	var tv xmltvTV
	if err := xml.Unmarshal(body, &tv); err != nil {
		log.Printf("EPG parse failed for playlist %d: %v", playlistID, err)
		return
	}

	tx, err := database.DB.Begin()
	if err != nil {
		log.Printf("EPG db transaction failed for playlist %d: %v", playlistID, err)
		return
	}
	defer tx.Rollback()

	if _, err := tx.Exec(`DELETE FROM epg_cache WHERE playlist_id = ?`, playlistID); err != nil {
		log.Printf("EPG cache clear failed for playlist %d: %v", playlistID, err)
		return
	}

	stmt, err := tx.Prepare(
		`INSERT OR REPLACE INTO epg_cache (channel_epg_id, playlist_id, start_time, end_time, title, description)
		 VALUES (?, ?, ?, ?, ?, ?)`,
	)
	if err != nil {
		log.Printf("EPG insert prepare failed for playlist %d: %v", playlistID, err)
		return
	}
	defer stmt.Close()

	for _, prog := range tv.Programmes {
		start, err := parseXMLTVTime(prog.Start)
		if err != nil {
			continue
		}
		end, err := parseXMLTVTime(prog.Stop)
		if err != nil {
			continue
		}
		if _, err := stmt.Exec(prog.Channel, playlistID, start, end, prog.Title.Value, prog.Desc.Value); err != nil {
			log.Printf("EPG insert failed for playlist %d channel %q: %v", playlistID, prog.Channel, err)
		}
	}

	if _, err := tx.Exec(
		`INSERT OR REPLACE INTO epg_fetch_log (playlist_id, fetched_at) VALUES (?, ?)`,
		playlistID, time.Now(),
	); err != nil {
		log.Printf("EPG fetch log update failed for playlist %d: %v", playlistID, err)
		return
	}

	if err := tx.Commit(); err != nil {
		log.Printf("EPG commit failed for playlist %d: %v", playlistID, err)
	}
}
