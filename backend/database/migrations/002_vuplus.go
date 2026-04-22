package migrations

// V2 recreates the playlists table with an updated type CHECK and vuplus columns.
var V2 = []string{
	`ALTER TABLE playlists RENAME TO playlists_v1`,
	`CREATE TABLE playlists (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		user_id INTEGER NOT NULL,
		name TEXT NOT NULL,
		type TEXT NOT NULL CHECK(type IN ('m3u', 'xtream', 'vuplus')),
		m3u_url TEXT,
		xtream_server TEXT,
		xtream_username TEXT,
		xtream_password TEXT,
		vuplus_ip TEXT,
		vuplus_port TEXT,
		epg_url TEXT,
		last_refreshed DATETIME,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
	)`,
	`INSERT INTO playlists (id, user_id, name, type, m3u_url, xtream_server, xtream_username, xtream_password, epg_url, last_refreshed, created_at)
	 SELECT id, user_id, name, type, m3u_url, xtream_server, xtream_username, xtream_password, epg_url, last_refreshed, created_at FROM playlists_v1`,
	`DROP TABLE playlists_v1`,
}
