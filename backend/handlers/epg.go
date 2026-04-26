package handlers

import (
	"bytes"
	"compress/gzip"
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

type vuplusEPGList struct {
	Events []vuplusEPGEvent `xml:"e2event"`
}

type vuplusEPGEvent struct {
	ServiceReference    string `xml:"e2eventservicereference"`
	Start               string `xml:"e2eventstart"`
	Duration            string `xml:"e2eventduration"`
	Title               string `xml:"e2eventtitle"`
	Description         string `xml:"e2eventdescription"`
	DescriptionExtended string `xml:"e2eventdescriptionextended"`
}

var xmltvLayouts = []string{
	"20060102150405 -0700",
	"20060102150405 +0000",
	"20060102150405-0700",
	"20060102150405+0000",
	"20060102150405",
	time.RFC3339,
}

func parseXMLTVTime(s string) (time.Time, error) {
	raw := strings.TrimSpace(s)
	if raw == "" {
		return time.Time{}, fmt.Errorf("cannot parse empty time")
	}

	// XMLTV often appends timezone names, e.g. "20260102150405 +0200 CET".
	fields := strings.Fields(raw)
	if len(fields) >= 2 {
		raw = fields[0] + " " + fields[1]
	} else {
		raw = fields[0]
	}

	for _, layout := range xmltvLayouts {
		if t, err := time.Parse(layout, raw); err == nil {
			return t, nil
		}
	}
	return time.Time{}, fmt.Errorf("cannot parse time: %s", s)
}

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

func readPossiblyGzippedBody(r io.Reader, contentEncoding string) ([]byte, error) {
	body, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}

	isGzip := strings.Contains(strings.ToLower(contentEncoding), "gzip") ||
		bytes.HasPrefix(body, []byte{0x1f, 0x8b})
	if !isGzip {
		return body, nil
	}

	gz, err := gzip.NewReader(bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	defer gz.Close()

	return io.ReadAll(gz)
}

func fetchVuplusEPGEvents(vuplusIP, vuplusPort, serviceRef string) ([]vuplusEPGEvent, error) {
	epqURL := fmt.Sprintf(
		"http://%s:%s/web/epgservice?sRef=%s",
		vuplusIP,
		vuplusPort,
		url.QueryEscape(serviceRef),
	)

	client := &http.Client{Timeout: 8 * time.Second}
	resp, err := client.Get(epqURL)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		return nil, fmt.Errorf("unexpected status %d", resp.StatusCode)
	}

	body, err := readPossiblyGzippedBody(resp.Body, resp.Header.Get("Content-Encoding"))
	if err != nil {
		return nil, err
	}

	var events vuplusEPGList
	if err := xml.Unmarshal(body, &events); err != nil {
		return nil, err
	}

	return events.Events, nil
}

func GetEPG(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r)
	playlistID, err := strconv.ParseInt(chi.URLParam(r, "playlist_id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid playlist_id")
		return
	}
	channelEpgID := chi.URLParam(r, "channel_epg_id")
	channelEpgID = strings.TrimSpace(channelEpgID)
	if channelEpgID == "" {
		writeError(w, http.StatusBadRequest, "invalid channel_epg_id")
		return
	}

	log.Printf("[EPG-DEBUG] GetEPG request user_id=%d playlist_id=%d channel_epg_id=%q", userID, playlistID, channelEpgID)

	if _, ok := ownsPlaylist(userID, playlistID); !ok {
		writeError(w, http.StatusNotFound, "playlist not found")
		return
	}

	var playlistType string
	if err := database.DB.QueryRow(`SELECT type FROM playlists WHERE id = ?`, playlistID).Scan(&playlistType); err != nil {
		writeError(w, http.StatusInternalServerError, "db error")
		return
	}
	log.Printf("[EPG-DEBUG] GetEPG playlist_id=%d type=%s", playlistID, playlistType)

	if playlistType == "vuplus" {
		refreshVuplusEPGForChannel(playlistID, channelEpgID)
	} else {
		// Refresh EPG if cache is stale
		var fetchedAt time.Time
		if err := database.DB.QueryRow(
			`SELECT fetched_at FROM epg_fetch_log WHERE playlist_id = ?`, playlistID,
		).Scan(&fetchedAt); err != nil {
			log.Printf("[EPG-DEBUG] GetEPG playlist_id=%d no previous fetch log (or lookup error): %v", playlistID, err)
		}

		if !fetchedAt.IsZero() {
			log.Printf("[EPG-DEBUG] GetEPG playlist_id=%d last_fetched_at=%s age=%s", playlistID, fetchedAt.Format(time.RFC3339), time.Since(fetchedAt).Round(time.Second))
		}

		if time.Since(fetchedAt) > epgCacheTTL {
			log.Printf("[EPG-DEBUG] GetEPG playlist_id=%d triggering refreshEPG (stale or empty cache)", playlistID)
			refreshEPG(playlistID)
		}
	}

	normalizedChannelEpgID := normalizeVuplusServiceRef(channelEpgID)
	rows, err := database.DB.Query(
		`SELECT channel_epg_id, start_time, end_time, title, description
		 FROM epg_cache
		 WHERE playlist_id = ?
		   AND end_time > ?
		   AND (
			 channel_epg_id = ?
			 OR LOWER(channel_epg_id) = LOWER(?)
			 OR channel_epg_id = ?
			 OR LOWER(channel_epg_id) = LOWER(?)
		   )
		 ORDER BY start_time ASC
		 LIMIT 48`,
		playlistID,
		time.Now().Add(-time.Hour),
		channelEpgID,
		channelEpgID,
		normalizedChannelEpgID,
		normalizedChannelEpgID,
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
	if err := rows.Err(); err != nil {
		log.Printf("[EPG-DEBUG] GetEPG rows iteration error playlist_id=%d channel_epg_id=%q: %v", playlistID, channelEpgID, err)
	}
	log.Printf("[EPG-DEBUG] GetEPG result playlist_id=%d requested_channel=%q normalized_channel=%q entries=%d", playlistID, channelEpgID, normalizedChannelEpgID, len(entries))
	writeJSON(w, http.StatusOK, entries)
}

func refreshEPG(playlistID int64) {
	var epgURL string
	if err := database.DB.QueryRow(
		`SELECT COALESCE(epg_url, '') FROM playlists WHERE id = ?`, playlistID,
	).Scan(&epgURL); err != nil || epgURL == "" {
		if err != nil {
			log.Printf("EPG source lookup failed for playlist %d: %v", playlistID, err)
		} else {
			log.Printf("EPG refresh skipped for playlist %d: epg_url is empty", playlistID)
		}
		return
	}
	epgURL = strings.TrimSpace(epgURL)
	log.Printf("[EPG-DEBUG] refreshEPG start playlist_id=%d epg_url=%q", playlistID, epgURL)

	resp, err := http.Get(epgURL)
	if err != nil {
		log.Printf("EPG fetch failed for playlist %d: %v", playlistID, err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		log.Printf("EPG fetch failed for playlist %d: unexpected status %d", playlistID, resp.StatusCode)
		return
	}
	log.Printf("[EPG-DEBUG] refreshEPG fetch playlist_id=%d status=%d content_encoding=%q", playlistID, resp.StatusCode, resp.Header.Get("Content-Encoding"))

	body, err := readPossiblyGzippedBody(resp.Body, resp.Header.Get("Content-Encoding"))
	if err != nil {
		log.Printf("EPG read failed for playlist %d: %v", playlistID, err)
		return
	}

	var tv xmltvTV
	if err := xml.Unmarshal(body, &tv); err != nil {
		log.Printf("EPG parse failed for playlist %d: %v", playlistID, err)
		return
	}
	log.Printf("[EPG-DEBUG] refreshEPG parsed playlist_id=%d body_bytes=%d programmes=%d", playlistID, len(body), len(tv.Programmes))

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

	inserted := 0
	skippedStart := 0
	skippedStop := 0
	skippedChannel := 0
	insertErrors := 0
	for _, prog := range tv.Programmes {
		start, err := parseXMLTVTime(prog.Start)
		if err != nil {
			skippedStart++
			continue
		}
		end, err := parseXMLTVTime(prog.Stop)
		if err != nil {
			skippedStop++
			continue
		}
		channelID := strings.TrimSpace(prog.Channel)
		if channelID == "" {
			skippedChannel++
			continue
		}
		if _, err := stmt.Exec(channelID, playlistID, start, end, prog.Title.Value, prog.Desc.Value); err != nil {
			log.Printf("EPG insert failed for playlist %d channel %q: %v", playlistID, prog.Channel, err)
			insertErrors++
			continue
		}
		inserted++
	}
	log.Printf("[EPG-DEBUG] refreshEPG insert stats playlist_id=%d inserted=%d skipped_start=%d skipped_stop=%d skipped_channel=%d insert_errors=%d", playlistID, inserted, skippedStart, skippedStop, skippedChannel, insertErrors)

	if _, err := tx.Exec(
		`INSERT OR REPLACE INTO epg_fetch_log (playlist_id, fetched_at) VALUES (?, ?)`,
		playlistID, time.Now(),
	); err != nil {
		log.Printf("EPG fetch log update failed for playlist %d: %v", playlistID, err)
		return
	}

	if err := tx.Commit(); err != nil {
		log.Printf("EPG commit failed for playlist %d: %v", playlistID, err)
		return
	}
	log.Printf("[EPG-DEBUG] refreshEPG done playlist_id=%d", playlistID)
}

func refreshVuplusEPGForChannel(playlistID int64, channelEpgID string) {
	var vuplusIP string
	var vuplusPort string
	if err := database.DB.QueryRow(
		`SELECT COALESCE(vuplus_ip, ''), COALESCE(vuplus_port, '80') FROM playlists WHERE id = ?`, playlistID,
	).Scan(&vuplusIP, &vuplusPort); err != nil {
		log.Printf("Vu+ EPG source lookup failed for playlist %d: %v", playlistID, err)
		return
	}

	vuplusIP = strings.TrimSpace(vuplusIP)
	vuplusPort = strings.TrimSpace(vuplusPort)
	if vuplusIP == "" {
		log.Printf("Vu+ EPG refresh skipped for playlist %d: vuplus_ip is empty", playlistID)
		return
	}
	if vuplusPort == "" {
		vuplusPort = "80"
	}
	log.Printf("[EPG-DEBUG] refreshVuplusEPGForChannel start playlist_id=%d host=%s:%s channel_epg_id=%q", playlistID, vuplusIP, vuplusPort, channelEpgID)

	events, err := fetchVuplusEPGEvents(vuplusIP, vuplusPort, channelEpgID)
	if err != nil {
		log.Printf("Vu+ EPG fetch failed for playlist %d channel %q: %v", playlistID, channelEpgID, err)
		return
	}
	log.Printf("[EPG-DEBUG] Vu+ primary fetch playlist_id=%d channel_epg_id=%q events=%d", playlistID, channelEpgID, len(events))

	if len(events) == 0 {
		normalizedRef := normalizeVuplusServiceRef(channelEpgID)
		if normalizedRef != "" && normalizedRef != channelEpgID {
			log.Printf("[EPG-DEBUG] Vu+ fallback fetch playlist_id=%d original_ref=%q normalized_ref=%q", playlistID, channelEpgID, normalizedRef)
			fallbackEvents, fallbackErr := fetchVuplusEPGEvents(vuplusIP, vuplusPort, normalizedRef)
			if fallbackErr == nil {
				events = fallbackEvents
				log.Printf("[EPG-DEBUG] Vu+ fallback fetch success playlist_id=%d normalized_ref=%q events=%d", playlistID, normalizedRef, len(events))
			} else {
				log.Printf("[EPG-DEBUG] Vu+ fallback fetch failed playlist_id=%d normalized_ref=%q err=%v", playlistID, normalizedRef, fallbackErr)
			}
		}
	}

	tx, err := database.DB.Begin()
	if err != nil {
		log.Printf("Vu+ EPG db transaction failed for playlist %d: %v", playlistID, err)
		return
	}
	defer tx.Rollback()

	if _, err := tx.Exec(
		`DELETE FROM epg_cache WHERE playlist_id = ? AND channel_epg_id = ?`,
		playlistID,
		channelEpgID,
	); err != nil {
		log.Printf("Vu+ EPG cache clear failed for playlist %d channel %q: %v", playlistID, channelEpgID, err)
		return
	}

	stmt, err := tx.Prepare(
		`INSERT OR REPLACE INTO epg_cache (channel_epg_id, playlist_id, start_time, end_time, title, description)
		 VALUES (?, ?, ?, ?, ?, ?)`,
	)
	if err != nil {
		log.Printf("Vu+ EPG insert prepare failed for playlist %d: %v", playlistID, err)
		return
	}
	defer stmt.Close()

	inserted := 0
	skippedStart := 0
	skippedDuration := 0
	insertErrors := 0
	for _, event := range events {
		startUnix, err := strconv.ParseInt(strings.TrimSpace(event.Start), 10, 64)
		if err != nil {
			skippedStart++
			continue
		}
		durationSec, err := strconv.ParseInt(strings.TrimSpace(event.Duration), 10, 64)
		if err != nil || durationSec <= 0 {
			skippedDuration++
			continue
		}

		start := time.Unix(startUnix, 0)
		end := start.Add(time.Duration(durationSec) * time.Second)

		description := strings.TrimSpace(event.Description)
		extended := strings.TrimSpace(event.DescriptionExtended)
		if description == "" {
			description = extended
		} else if extended != "" && !strings.Contains(description, extended) {
			description = description + "\n\n" + extended
		}

		// Persist under the requested channel ID so GetEPG lookups stay stable.
		if _, err := stmt.Exec(channelEpgID, playlistID, start, end, strings.TrimSpace(event.Title), description); err != nil {
			log.Printf("Vu+ EPG insert failed for playlist %d channel %q: %v", playlistID, channelEpgID, err)
			insertErrors++
			continue
		}
		inserted++
	}
	log.Printf("[EPG-DEBUG] Vu+ insert stats playlist_id=%d channel_epg_id=%q source_events=%d inserted=%d skipped_start=%d skipped_duration=%d insert_errors=%d", playlistID, channelEpgID, len(events), inserted, skippedStart, skippedDuration, insertErrors)

	if _, err := tx.Exec(
		`INSERT OR REPLACE INTO epg_fetch_log (playlist_id, fetched_at) VALUES (?, ?)`,
		playlistID, time.Now(),
	); err != nil {
		log.Printf("Vu+ EPG fetch log update failed for playlist %d: %v", playlistID, err)
		return
	}

	if err := tx.Commit(); err != nil {
		log.Printf("Vu+ EPG commit failed for playlist %d: %v", playlistID, err)
		return
	}
	log.Printf("[EPG-DEBUG] refreshVuplusEPGForChannel done playlist_id=%d channel_epg_id=%q", playlistID, channelEpgID)
}
