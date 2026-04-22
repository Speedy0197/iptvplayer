package database

import "github.com/flodev/iptvplayer/models"

// GetPlaylistForUser fetches a playlist by ID verifying user ownership.
func GetPlaylistForUser(playlistID, userID int64) (models.Playlist, error) {
	var p models.Playlist
	err := DB.QueryRow(
		`SELECT id, user_id, name, type, m3u_url, m3u_content, xtream_server, xtream_username, xtream_password,
		        vuplus_ip, vuplus_port, epg_url, last_refreshed, created_at
		 FROM playlists WHERE id = ? AND user_id = ?`, playlistID, userID,
	).Scan(&p.ID, &p.UserID, &p.Name, &p.Type, &p.M3UURL, &p.M3UContent,
		&p.XtreamServer, &p.XtreamUsername, &p.XtreamPassword,
		&p.VuplusIP, &p.VuplusPort,
		&p.EpgURL, &p.LastRefreshed, &p.CreatedAt)
	return p, err
}
