package handlers

import (
	"bytes"
	"compress/gzip"
	"database/sql"
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
	"unicode"

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

type vuplusSimpleResult struct {
	State     string `xml:"e2state"`
	StateText string `xml:"e2statetext"`
}

type vuplusRecordEPGRequest struct {
	ChannelEpgID string `json:"channel_epg_id"`
	StartTime    string `json:"start_time"`
	EndTime      string `json:"end_time"`
	Title        string `json:"title"`
	Description  string `json:"description"`
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

func isNumericUTCOffset(s string) bool {
	if len(s) != 5 {
		return false
	}
	if s[0] != '+' && s[0] != '-' {
		return false
	}
	for i := 1; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

func normalizeStoredEPGTime(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return raw
	}

	parts := strings.Fields(raw)
	if len(parts) >= 4 && isNumericUTCOffset(parts[2]) {
		return strings.Join(parts[:3], " ")
	}
	if len(parts) == 3 && isNumericUTCOffset(parts[2]) {
		return strings.Join(parts[:3], " ")
	}
	return raw
}

func parseStoredEPGTime(raw string) (time.Time, error) {
	normalized := normalizeStoredEPGTime(raw)
	layouts := []string{
		time.RFC3339Nano,
		time.RFC3339,
		"2006-01-02 15:04:05 -0700",
		"2006-01-02 15:04:05",
	}
	for _, layout := range layouts {
		if parsed, err := time.Parse(layout, normalized); err == nil {
			return parsed, nil
		}
	}
	return time.Time{}, fmt.Errorf("unable to parse time value %q", raw)
}

func formatEPGTimeForDB(t time.Time) string {
	return t.UTC().Format(time.RFC3339)
}

func scanEPGEntries(rows *sql.Rows, since *time.Time, descending bool, limit int) ([]models.EPGEntry, error) {
	entries := []models.EPGEntry{}
	for rows.Next() {
		var channelID string
		var startRaw string
		var endRaw string
		var title string
		var description string
		if err := rows.Scan(&channelID, &startRaw, &endRaw, &title, &description); err != nil {
			continue
		}

		startTime, err := parseStoredEPGTime(startRaw)
		if err != nil {
			continue
		}
		endTime, err := parseStoredEPGTime(endRaw)
		if err != nil {
			continue
		}

		if since != nil && !endTime.After(*since) {
			continue
		}

		entries = append(entries, models.EPGEntry{
			ChannelEpgID: channelID,
			StartTime:    startTime,
			EndTime:      endTime,
			Title:        title,
			Description:  description,
		})
		if limit > 0 && len(entries) >= limit {
			break
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	if descending {
		for left, right := 0, len(entries)-1; left < right; left, right = left+1, right-1 {
			entries[left], entries[right] = entries[right], entries[left]
		}
	}

	return entries, nil
}

func queryEPGEntriesSince(playlistID int64, channelEpgID string, since time.Time) ([]models.EPGEntry, error) {
	normalizedChannelEpgID := normalizeVuplusServiceRef(channelEpgID)
	rows, err := database.DB.Query(
		`SELECT channel_epg_id, start_time, end_time, title, description
		 FROM epg_cache
		 WHERE playlist_id = ?
		   AND (
			 channel_epg_id = ?
			 OR LOWER(channel_epg_id) = LOWER(?)
			 OR channel_epg_id = ?
			 OR LOWER(channel_epg_id) = LOWER(?)
		   )
		 ORDER BY start_time ASC
		 LIMIT 256`,
		playlistID,
		channelEpgID,
		channelEpgID,
		normalizedChannelEpgID,
		normalizedChannelEpgID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	return scanEPGEntries(rows, &since, false, 48)
}

func queryEPGEntries(playlistID int64, channelEpgID string) ([]models.EPGEntry, error) {
	return queryEPGEntriesSince(playlistID, channelEpgID, time.Now().Add(-time.Hour))
}

func queryLatestEPGEntries(playlistID int64, channelEpgID string) ([]models.EPGEntry, error) {
	normalizedChannelEpgID := normalizeVuplusServiceRef(channelEpgID)
	rows, err := database.DB.Query(
		`SELECT channel_epg_id, start_time, end_time, title, description
		 FROM epg_cache
		 WHERE playlist_id = ?
		   AND (
			 channel_epg_id = ?
			 OR LOWER(channel_epg_id) = LOWER(?)
			 OR channel_epg_id = ?
			 OR LOWER(channel_epg_id) = LOWER(?)
		   )
		 ORDER BY start_time DESC
		 LIMIT 48`,
		playlistID,
		channelEpgID,
		channelEpgID,
		normalizedChannelEpgID,
		normalizedChannelEpgID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	return scanEPGEntries(rows, nil, true, 48)
}

func countEPGEntriesForChannel(playlistID int64, channelEpgID string) (int, error) {
	normalizedChannelEpgID := normalizeVuplusServiceRef(channelEpgID)
	var count int
	err := database.DB.QueryRow(
		`SELECT COUNT(*)
		 FROM epg_cache
		 WHERE playlist_id = ?
		   AND (
			 channel_epg_id = ?
			 OR LOWER(channel_epg_id) = LOWER(?)
			 OR channel_epg_id = ?
			 OR LOWER(channel_epg_id) = LOWER(?)
		   )`,
		playlistID,
		channelEpgID,
		channelEpgID,
		normalizedChannelEpgID,
		normalizedChannelEpgID,
	).Scan(&count)
	if err != nil {
		return 0, err
	}
	return count, nil
}

func getEPGTimeBoundsForChannel(playlistID int64, channelEpgID string) (*time.Time, *time.Time, error) {
	normalizedChannelEpgID := normalizeVuplusServiceRef(channelEpgID)
	var minStart sqlNullTime
	var maxEnd sqlNullTime
	err := database.DB.QueryRow(
		`SELECT MIN(start_time), MAX(end_time)
		 FROM epg_cache
		 WHERE playlist_id = ?
		   AND (
			 channel_epg_id = ?
			 OR LOWER(channel_epg_id) = LOWER(?)
			 OR channel_epg_id = ?
			 OR LOWER(channel_epg_id) = LOWER(?)
		   )`,
		playlistID,
		channelEpgID,
		channelEpgID,
		normalizedChannelEpgID,
		normalizedChannelEpgID,
	).Scan(&minStart, &maxEnd)
	if err != nil {
		return nil, nil, err
	}

	var startPtr *time.Time
	var endPtr *time.Time
	if minStart.Valid {
		startVal := minStart.Time
		startPtr = &startVal
	}
	if maxEnd.Valid {
		endVal := maxEnd.Time
		endPtr = &endVal
	}

	return startPtr, endPtr, nil
}

type sqlNullTime struct {
	Time  time.Time
	Valid bool
}

func (nt *sqlNullTime) Scan(value any) error {
	if value == nil {
		nt.Time = time.Time{}
		nt.Valid = false
		return nil
	}

	switch v := value.(type) {
	case time.Time:
		nt.Time = v
		nt.Valid = true
		return nil
	case string:
		return nt.parseString(v)
	case []byte:
		return nt.parseString(string(v))
	default:
		return fmt.Errorf("unsupported time scan type %T", value)
	}
}

func (nt *sqlNullTime) parseString(value string) error {
	value = strings.TrimSpace(value)
	if value == "" {
		nt.Time = time.Time{}
		nt.Valid = false
		return nil
	}

	parsed, err := parseStoredEPGTime(value)
	if err != nil {
		return err
	}
	nt.Time = parsed
	nt.Valid = true
	return nil
}

func normalizeEPGKey(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range strings.ToLower(strings.TrimSpace(s)) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func epgKeyTokens(s string) []string {
	parts := strings.FieldsFunc(strings.ToLower(strings.TrimSpace(s)), func(r rune) bool {
		return !(unicode.IsLetter(r) || unicode.IsDigit(r))
	})

	stop := map[string]struct{}{
		"de":  {},
		"com": {},
		"net": {},
		"org": {},
		"tv":  {},
		"hd":  {},
		"uhd": {},
		"sd":  {},
	}

	seen := map[string]struct{}{}
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if len(p) < 2 {
			continue
		}
		if _, isStop := stop[p]; isStop {
			continue
		}
		if _, exists := seen[p]; exists {
			continue
		}
		seen[p] = struct{}{}
		out = append(out, p)
	}

	return out
}

func scoreEPGAliasCandidate(requestedID, channelName, candidateID string) int {
	candidate := strings.TrimSpace(candidateID)
	if candidate == "" {
		return 0
	}

	req := strings.TrimSpace(requestedID)
	name := strings.TrimSpace(channelName)

	normCand := normalizeEPGKey(candidate)
	targets := []string{req}
	if name != "" {
		targets = append(targets, name)
	}

	best := 0
	for _, target := range targets {
		target = strings.TrimSpace(target)
		if target == "" {
			continue
		}

		if strings.EqualFold(candidate, target) {
			if 1000 > best {
				best = 1000
			}
			continue
		}

		normTarget := normalizeEPGKey(target)
		if normTarget == "" {
			continue
		}

		if normCand == normTarget {
			if 900 > best {
				best = 900
			}
			continue
		}

		if len(normTarget) >= 4 && (strings.Contains(normCand, normTarget) || strings.Contains(normTarget, normCand)) {
			score := 700 - absInt(len(normCand)-len(normTarget))
			if score > best {
				best = score
			}
		}

		tokensTarget := epgKeyTokens(target)
		tokensCand := epgKeyTokens(candidate)
		if len(tokensTarget) == 0 || len(tokensCand) == 0 {
			continue
		}

		candSet := map[string]struct{}{}
		for _, t := range tokensCand {
			candSet[t] = struct{}{}
		}

		overlap := 0
		for _, t := range tokensTarget {
			if _, ok := candSet[t]; ok {
				overlap++
			}
		}
		if overlap > 0 {
			score := overlap * 120
			if score > best {
				best = score
			}
		}
	}

	return best
}

func absInt(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

func findEPGAliasChannelID(playlistID int64, requestedID string) (string, int, error) {
	requestedID = strings.TrimSpace(requestedID)
	if requestedID == "" {
		return "", 0, nil
	}

	channelName := ""
	if err := database.DB.QueryRow(
		`SELECT COALESCE(name, '') FROM channels WHERE playlist_id = ? AND (epg_channel_id = ? OR LOWER(epg_channel_id) = LOWER(?)) LIMIT 1`,
		playlistID, requestedID, requestedID,
	).Scan(&channelName); err != nil && err.Error() != "sql: no rows in result set" {
		return "", 0, err
	}

	rows, err := database.DB.Query(
		`SELECT DISTINCT channel_epg_id
		 FROM epg_cache
		 WHERE playlist_id = ? AND end_time > ?`,
		playlistID, time.Now().Add(-24*time.Hour),
	)
	if err != nil {
		return "", 0, err
	}
	defer rows.Close()

	bestID := ""
	bestScore := 0
	for rows.Next() {
		var candidate string
		if err := rows.Scan(&candidate); err != nil {
			continue
		}
		score := scoreEPGAliasCandidate(requestedID, channelName, candidate)
		if score > bestScore {
			bestScore = score
			bestID = candidate
		}
	}
	if err := rows.Err(); err != nil {
		return "", 0, err
	}

	if bestScore < 180 {
		return "", bestScore, nil
	}

	return bestID, bestScore, nil
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

	didRefresh := false
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
			didRefresh = true
		}
	}

	normalizedChannelEpgID := normalizeVuplusServiceRef(channelEpgID)
	entries, err := queryEPGEntries(playlistID, channelEpgID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "db error")
		return
	}

	if playlistType != "vuplus" && len(entries) == 0 {
		totalEntries, countErr := countEPGEntriesForChannel(playlistID, channelEpgID)
		if countErr != nil {
			log.Printf("[EPG-DEBUG] GetEPG total count lookup failed playlist_id=%d channel_epg_id=%q: %v", playlistID, channelEpgID, countErr)
		} else {
			log.Printf("[EPG-DEBUG] GetEPG zero active entries playlist_id=%d channel_epg_id=%q total_exact_entries=%d", playlistID, channelEpgID, totalEntries)
			if totalEntries > 0 {
				minStart, maxEnd, boundsErr := getEPGTimeBoundsForChannel(playlistID, channelEpgID)
				if boundsErr != nil {
					log.Printf("[EPG-DEBUG] GetEPG time bounds lookup failed playlist_id=%d channel_epg_id=%q: %v", playlistID, channelEpgID, boundsErr)
				} else if minStart != nil && maxEnd != nil {
					log.Printf("[EPG-DEBUG] GetEPG cached time bounds playlist_id=%d channel_epg_id=%q min_start=%s max_end=%s now=%s", playlistID, channelEpgID, minStart.Format(time.RFC3339), maxEnd.Format(time.RFC3339), time.Now().Format(time.RFC3339))
				}
			}
		}

		aliasID, aliasScore, aliasErr := findEPGAliasChannelID(playlistID, channelEpgID)
		if aliasErr != nil {
			log.Printf("[EPG-DEBUG] GetEPG alias lookup failed playlist_id=%d channel_epg_id=%q: %v", playlistID, channelEpgID, aliasErr)
		} else if aliasID != "" {
			log.Printf("[EPG-DEBUG] GetEPG alias match playlist_id=%d requested_channel=%q alias_channel=%q score=%d", playlistID, channelEpgID, aliasID, aliasScore)
			entries, err = queryEPGEntries(playlistID, aliasID)
			if err != nil {
				writeError(w, http.StatusInternalServerError, "db error")
				return
			}
			if len(entries) == 0 {
				entries, err = queryEPGEntriesSince(playlistID, aliasID, time.Now().Add(-24*time.Hour))
				if err != nil {
					writeError(w, http.StatusInternalServerError, "db error")
					return
				}
				if len(entries) > 0 {
					log.Printf("[EPG-DEBUG] GetEPG alias fallback window hit playlist_id=%d alias_channel=%q entries=%d", playlistID, aliasID, len(entries))
				}
			}
		}

		if len(entries) == 0 && totalEntries > 0 {
			entries, err = queryLatestEPGEntries(playlistID, channelEpgID)
			if err != nil {
				writeError(w, http.StatusInternalServerError, "db error")
				return
			}
			if len(entries) > 0 {
				log.Printf("[EPG-DEBUG] GetEPG latest-entry fallback hit playlist_id=%d channel_epg_id=%q entries=%d", playlistID, channelEpgID, len(entries))
			}
		}

		if len(entries) == 0 && !didRefresh {
			log.Printf("[EPG-DEBUG] GetEPG empty result for non-vuplus playlist_id=%d channel_epg_id=%q, forcing refreshEPG once", playlistID, channelEpgID)
			refreshEPG(playlistID)
			entries, err = queryEPGEntries(playlistID, channelEpgID)
			if err != nil {
				writeError(w, http.StatusInternalServerError, "db error")
				return
			}

			if len(entries) == 0 {
				aliasID, aliasScore, aliasErr = findEPGAliasChannelID(playlistID, channelEpgID)
				if aliasErr != nil {
					log.Printf("[EPG-DEBUG] GetEPG alias lookup failed post-refresh playlist_id=%d channel_epg_id=%q: %v", playlistID, channelEpgID, aliasErr)
				} else if aliasID != "" {
					log.Printf("[EPG-DEBUG] GetEPG alias match post-refresh playlist_id=%d requested_channel=%q alias_channel=%q score=%d", playlistID, channelEpgID, aliasID, aliasScore)
					entries, err = queryEPGEntries(playlistID, aliasID)
					if err != nil {
						writeError(w, http.StatusInternalServerError, "db error")
						return
					}
					if len(entries) == 0 {
						entries, err = queryEPGEntriesSince(playlistID, aliasID, time.Now().Add(-24*time.Hour))
						if err != nil {
							writeError(w, http.StatusInternalServerError, "db error")
							return
						}
						if len(entries) > 0 {
							log.Printf("[EPG-DEBUG] GetEPG alias fallback window hit post-refresh playlist_id=%d alias_channel=%q entries=%d", playlistID, aliasID, len(entries))
						}
					}
				}
			}
		}

		if !didRefresh {
			log.Printf("[EPG-DEBUG] GetEPG post-refresh result playlist_id=%d channel_epg_id=%q entries=%d", playlistID, channelEpgID, len(entries))
		} else {
			log.Printf("[EPG-DEBUG] GetEPG post-alias result playlist_id=%d channel_epg_id=%q entries=%d", playlistID, channelEpgID, len(entries))
		}
	}

	log.Printf("[EPG-DEBUG] GetEPG result playlist_id=%d requested_channel=%q normalized_channel=%q entries=%d", playlistID, channelEpgID, normalizedChannelEpgID, len(entries))
	writeJSON(w, http.StatusOK, entries)
}

func RecordVuplusEPG(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r)
	playlistID, err := strconv.ParseInt(chi.URLParam(r, "playlist_id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid playlist_id")
		return
	}

	if _, ok := ownsPlaylist(userID, playlistID); !ok {
		writeError(w, http.StatusNotFound, "playlist not found")
		return
	}

	var req vuplusRecordEPGRequest
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	channelEpgID := strings.TrimSpace(req.ChannelEpgID)
	if channelEpgID == "" {
		writeError(w, http.StatusBadRequest, "channel_epg_id is required")
		return
	}

	startTime, err := parseRequestTime(strings.TrimSpace(req.StartTime))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid start_time")
		return
	}
	endTime, err := parseRequestTime(strings.TrimSpace(req.EndTime))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid end_time")
		return
	}
	if !endTime.After(startTime) {
		writeError(w, http.StatusBadRequest, "end_time must be after start_time")
		return
	}

	title := strings.TrimSpace(req.Title)
	if title == "" {
		title = "Recording"
	}
	description := strings.TrimSpace(req.Description)

	var playlistType string
	var vuplusIP string
	var vuplusPort string
	if err := database.DB.QueryRow(
		`SELECT type, COALESCE(vuplus_ip, ''), COALESCE(vuplus_port, '80') FROM playlists WHERE id = ?`,
		playlistID,
	).Scan(&playlistType, &vuplusIP, &vuplusPort); err != nil {
		writeError(w, http.StatusInternalServerError, "db error")
		return
	}

	if playlistType != "vuplus" {
		writeError(w, http.StatusBadRequest, "recording is only supported for vuplus playlists")
		return
	}

	vuplusIP = strings.TrimSpace(vuplusIP)
	vuplusPort = strings.TrimSpace(vuplusPort)
	if vuplusIP == "" {
		writeError(w, http.StatusBadRequest, "vuplus_ip is missing")
		return
	}
	if vuplusPort == "" {
		vuplusPort = "80"
	}

	// The channel EPG ID is stored URL-encoded (chi keeps raw path params).
	// Decode it once so VU+ receives the plain service reference (e.g. "1:0:19:...").
	sRef, decodeErr := url.PathUnescape(channelEpgID)
	if decodeErr != nil {
		sRef = channelEpgID
	}

	if err := createVuplusRecordingTimer(vuplusIP, vuplusPort, sRef, startTime, endTime, title, description); err != nil {
		log.Printf("Vu+ recording timer create failed playlist_id=%d channel_epg_id=%q: %v", playlistID, channelEpgID, err)
		writeError(w, http.StatusBadGateway, "failed to create recording on vuplus device")
		return
	}

	writeJSON(w, http.StatusCreated, map[string]any{"ok": true})
}

func createVuplusRecordingTimer(
	vuplusIP, vuplusPort, channelEpgID string,
	startTime, endTime time.Time,
	title, description string,
) error {
	values := url.Values{}
	values.Set("sRef", channelEpgID)
	values.Set("begin", strconv.FormatInt(startTime.UTC().Unix(), 10))
	values.Set("end", strconv.FormatInt(endTime.UTC().Unix(), 10))
	values.Set("name", title)
	values.Set("description", description)
	values.Set("disabled", "0")
	values.Set("justplay", "0")
	values.Set("afterevent", "3")
	values.Set("repeated", "0")

	timerURL := fmt.Sprintf("http://%s:%s/web/timeradd?%s", vuplusIP, vuplusPort, values.Encode())

	client := &http.Client{Timeout: 8 * time.Second}
	resp, err := client.Get(timerURL)
	if err != nil {
		// VU+ OpenWebif often creates the timer but drops the connection
		// before sending a response. Treat any network/timeout error as
		// success — the caller can verify in OpenWebif if needed.
		if isNetworkOrTimeoutError(err) {
			log.Printf("Vu+ timeradd: ignoring network/timeout error (timer likely created): %v", err)
			return nil
		}
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		return fmt.Errorf("unexpected status %d", resp.StatusCode)
	}

	body, err := readPossiblyGzippedBody(resp.Body, resp.Header.Get("Content-Encoding"))
	if err != nil {
		return err
	}

	var result vuplusSimpleResult
	if err := xml.Unmarshal(body, &result); err != nil {
		return nil
	}

	state := strings.ToLower(strings.TrimSpace(result.State))
	if state == "false" || state == "0" || state == "no" {
		msg := strings.TrimSpace(result.StateText)
		if msg == "" {
			msg = "timer creation failed"
		}
		return fmt.Errorf(msg)
	}

	return nil
}

func GetVuplusTimers(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r)
	playlistID, err := strconv.ParseInt(chi.URLParam(r, "playlist_id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid playlist_id")
		return
	}

	if _, ok := ownsPlaylist(userID, playlistID); !ok {
		writeError(w, http.StatusNotFound, "playlist not found")
		return
	}

	var playlistType, vuplusIP, vuplusPort string
	if err := database.DB.QueryRow(
		`SELECT type, COALESCE(vuplus_ip, ''), COALESCE(vuplus_port, '80') FROM playlists WHERE id = ?`,
		playlistID,
	).Scan(&playlistType, &vuplusIP, &vuplusPort); err != nil {
		writeError(w, http.StatusInternalServerError, "db error")
		return
	}

	if playlistType != "vuplus" {
		writeJSON(w, http.StatusOK, []any{})
		return
	}

	vuplusIP = strings.TrimSpace(vuplusIP)
	vuplusPort = strings.TrimSpace(vuplusPort)
	if vuplusIP == "" {
		writeJSON(w, http.StatusOK, []any{})
		return
	}
	if vuplusPort == "" {
		vuplusPort = "80"
	}

	timers, err := fetchVuplusTimerList(vuplusIP, vuplusPort)
	if err != nil {
		log.Printf("Vu+ timer list fetch failed playlist_id=%d: %v", playlistID, err)
		writeJSON(w, http.StatusOK, []any{})
		return
	}

	writeJSON(w, http.StatusOK, timers)
}

type vuplusTimerListXML struct {
	Timers []vuplusTimerXML `xml:"e2timer"`
}

type vuplusTimerXML struct {
	ServiceRef string `xml:"e2servicereference"`
	Name       string `xml:"e2name"`
	Begin      string `xml:"e2timebegin"`
	End        string `xml:"e2timeend"`
	BeginAlt   string `xml:"e2begin"`
	EndAlt     string `xml:"e2end"`
	Disabled   string `xml:"e2disabled"`
}

type vuplusTimerEntry struct {
	ChannelEpgID string `json:"channel_epg_id"`
	BeginUnix    int64  `json:"begin_unix"`
	EndUnix      int64  `json:"end_unix"`
	Name         string `json:"name"`
}

func fetchVuplusTimerList(vuplusIP, vuplusPort string) ([]vuplusTimerEntry, error) {
	timerURL := fmt.Sprintf("http://%s:%s/web/timerlist", vuplusIP, vuplusPort)
	client := &http.Client{Timeout: 8 * time.Second}
	resp, err := client.Get(timerURL)
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

	var list vuplusTimerListXML
	if err := xml.Unmarshal(body, &list); err != nil {
		return nil, err
	}

	result := make([]vuplusTimerEntry, 0, len(list.Timers))
	for _, t := range list.Timers {
		if strings.TrimSpace(t.Disabled) == "1" {
			continue
		}
		sRef := strings.TrimSpace(t.ServiceRef)
		if sRef == "" {
			continue
		}
		beginRaw := strings.TrimSpace(t.Begin)
		if beginRaw == "" {
			beginRaw = strings.TrimSpace(t.BeginAlt)
		}
		endRaw := strings.TrimSpace(t.End)
		if endRaw == "" {
			endRaw = strings.TrimSpace(t.EndAlt)
		}

		begin, err := strconv.ParseInt(beginRaw, 10, 64)
		if err != nil {
			continue
		}
		end, _ := strconv.ParseInt(endRaw, 10, 64)
		result = append(result, vuplusTimerEntry{
			ChannelEpgID: sRef,
			BeginUnix:    begin,
			EndUnix:      end,
			Name:         strings.TrimSpace(t.Name),
		})
	}
	return result, nil
}

func parseRequestTime(raw string) (time.Time, error) {
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339} {
		if parsed, err := time.Parse(layout, raw); err == nil {
			return parsed, nil
		}
	}
	return time.Time{}, fmt.Errorf("invalid timestamp %q", raw)
}

// isNetworkOrTimeoutError reports whether err is a context deadline / timeout /
// EOF error. VU+ OpenWebif sometimes fires-and-forgets the response after
// creating a timer, so these errors should be treated as success.
func isNetworkOrTimeoutError(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	return strings.Contains(s, "context deadline exceeded") ||
		strings.Contains(s, "Client.Timeout") ||
		strings.Contains(s, "EOF") ||
		strings.Contains(s, "connection reset") ||
		strings.Contains(s, "broken pipe")
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
		if _, err := stmt.Exec(channelID, playlistID, formatEPGTimeForDB(start), formatEPGTimeForDB(end), prog.Title.Value, prog.Desc.Value); err != nil {
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
		if _, err := stmt.Exec(channelEpgID, playlistID, formatEPGTimeForDB(start), formatEPGTimeForDB(end), strings.TrimSpace(event.Title), description); err != nil {
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
