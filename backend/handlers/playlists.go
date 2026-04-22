package handlers

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"

	"github.com/flodev/iptvplayer/database"
	"github.com/flodev/iptvplayer/middleware"
	"github.com/flodev/iptvplayer/models"
	"github.com/go-chi/chi/v5"
)

func ListPlaylists(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r)

	rows, err := database.DB.Query(
		`SELECT id, user_id, name, type, m3u_url, xtream_server, xtream_username, xtream_password,
		        vuplus_ip, vuplus_port, epg_url, last_refreshed, created_at
		 FROM playlists WHERE user_id = ? ORDER BY created_at ASC`, userID,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "db error")
		return
	}
	defer rows.Close()

	playlists := []models.Playlist{}
	for rows.Next() {
		var p models.Playlist
		if err := rows.Scan(&p.ID, &p.UserID, &p.Name, &p.Type, &p.M3UURL,
			&p.XtreamServer, &p.XtreamUsername, &p.XtreamPassword,
			&p.VuplusIP, &p.VuplusPort,
			&p.EpgURL, &p.LastRefreshed, &p.CreatedAt); err != nil {
			writeError(w, http.StatusInternalServerError, "scan error")
			return
		}
		if p.XtreamPassword != nil {
			masked := "***"
			p.XtreamPassword = &masked
		}
		playlists = append(playlists, p)
	}

	writeJSON(w, http.StatusOK, playlists)
}

func CreatePlaylist(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r)

	var req struct {
		Name           string  `json:"name"`
		Type           string  `json:"type"`
		M3UURL         *string `json:"m3u_url"`
		M3UContent     *string `json:"m3u_content"`
		XtreamServer   *string `json:"xtream_server"`
		XtreamUsername *string `json:"xtream_username"`
		XtreamPassword *string `json:"xtream_password"`
		VuplusIP       *string `json:"vuplus_ip"`
		VuplusPort     *string `json:"vuplus_port"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}

	if err := validatePlaylistInput(
		req.Type,
		req.Name,
		req.M3UURL,
		req.M3UContent,
		req.XtreamServer,
		req.XtreamUsername,
		req.XtreamPassword,
		req.VuplusIP,
	); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	res, err := database.DB.Exec(
		`INSERT INTO playlists (user_id, name, type, m3u_url, m3u_content, xtream_server, xtream_username, xtream_password, vuplus_ip, vuplus_port)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		userID, req.Name, req.Type, req.M3UURL, req.M3UContent,
		req.XtreamServer, req.XtreamUsername, req.XtreamPassword,
		req.VuplusIP, req.VuplusPort,
	)
	if err != nil {
		log.Printf("create playlist failed user=%d type=%s name=%q: %v", userID, req.Type, req.Name, err)
		if isSQLiteBusy(err) {
			writeError(w, http.StatusServiceUnavailable, "database busy, please retry")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to create playlist")
		return
	}

	id, _ := res.LastInsertId()
	writeJSON(w, http.StatusCreated, map[string]any{"id": id, "name": req.Name, "type": req.Type})
}

func UpdatePlaylist(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r)
	playlistID, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}

	var existing models.Playlist
	err = database.DB.QueryRow(
		`SELECT id, user_id, name, type, m3u_url, m3u_content, xtream_server, xtream_username, xtream_password, vuplus_ip, vuplus_port, epg_url, last_refreshed, created_at
		 FROM playlists WHERE id = ? AND user_id = ?`,
		playlistID, userID,
	).Scan(
		&existing.ID,
		&existing.UserID,
		&existing.Name,
		&existing.Type,
		&existing.M3UURL,
		&existing.M3UContent,
		&existing.XtreamServer,
		&existing.XtreamUsername,
		&existing.XtreamPassword,
		&existing.VuplusIP,
		&existing.VuplusPort,
		&existing.EpgURL,
		&existing.LastRefreshed,
		&existing.CreatedAt,
	)
	if err != nil {
		writeError(w, http.StatusNotFound, "playlist not found")
		return
	}

	var req struct {
		Name           string  `json:"name"`
		Type           string  `json:"type"`
		M3UURL         *string `json:"m3u_url"`
		M3UContent     *string `json:"m3u_content"`
		XtreamServer   *string `json:"xtream_server"`
		XtreamUsername *string `json:"xtream_username"`
		XtreamPassword *string `json:"xtream_password"`
		VuplusIP       *string `json:"vuplus_ip"`
		VuplusPort     *string `json:"vuplus_port"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}

	if req.Type == "" {
		req.Type = existing.Type
	}
	if req.Name == "" {
		req.Name = existing.Name
	}

	if req.Type == "xtream" {
		if req.XtreamServer == nil {
			req.XtreamServer = existing.XtreamServer
		}
		if req.XtreamUsername == nil {
			req.XtreamUsername = existing.XtreamUsername
		}
		if req.XtreamPassword == nil || (req.XtreamPassword != nil && *req.XtreamPassword == "") {
			req.XtreamPassword = existing.XtreamPassword
		}
	}

	if err := validatePlaylistInput(
		req.Type,
		req.Name,
		req.M3UURL,
		req.M3UContent,
		req.XtreamServer,
		req.XtreamUsername,
		req.XtreamPassword,
		req.VuplusIP,
	); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	if req.Type != existing.Type {
		writeError(w, http.StatusBadRequest, "changing playlist type is not supported")
		return
	}

	_, err = database.DB.Exec(
		`UPDATE playlists
		 SET name = ?,
		     m3u_url = ?,
		     m3u_content = ?,
		     xtream_server = ?,
		     xtream_username = ?,
		     xtream_password = ?,
		     vuplus_ip = ?,
		     vuplus_port = ?,
		     epg_url = NULL,
		     last_refreshed = NULL
		 WHERE id = ? AND user_id = ?`,
		req.Name,
		req.M3UURL,
		req.M3UContent,
		req.XtreamServer,
		req.XtreamUsername,
		req.XtreamPassword,
		req.VuplusIP,
		req.VuplusPort,
		playlistID,
		userID,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to update playlist")
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"id": playlistID, "name": req.Name, "type": req.Type})
}

func validatePlaylistInput(
	typeValue string,
	name string,
	m3uURL *string,
	m3uContent *string,
	xtreamServer *string,
	xtreamUsername *string,
	xtreamPassword *string,
	vuplusIP *string,
) error {
	switch typeValue {
	case "m3u":
		hasURL := m3uURL != nil && *m3uURL != ""
		hasContent := m3uContent != nil && *m3uContent != ""
		if !hasURL && !hasContent {
			return errBadRequest("m3u_url or m3u_content required")
		}
	case "xtream":
		if xtreamServer == nil || *xtreamServer == "" || xtreamUsername == nil || *xtreamUsername == "" || xtreamPassword == nil || *xtreamPassword == "" {
			return errBadRequest("xtream_server, xtream_username, xtream_password required")
		}
	case "vuplus":
		if vuplusIP == nil || *vuplusIP == "" {
			return errBadRequest("vuplus_ip required")
		}
	default:
		return errBadRequest("type must be m3u, xtream, or vuplus")
	}

	if name == "" {
		return errBadRequest("name required")
	}

	return nil
}

type badRequestError struct{ msg string }

func (e badRequestError) Error() string { return e.msg }

func errBadRequest(msg string) error { return badRequestError{msg: msg} }

func DeletePlaylist(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r)
	playlistID, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}

	res, err := database.DB.Exec(
		`DELETE FROM playlists WHERE id = ? AND user_id = ?`, playlistID, userID,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "db error")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeError(w, http.StatusNotFound, "playlist not found")
		return
	}

	w.WriteHeader(http.StatusNoContent)
}
