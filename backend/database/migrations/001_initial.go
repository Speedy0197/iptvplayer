package migrations

var V1 = []string{
	`CREATE TABLE IF NOT EXISTS users (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		username TEXT UNIQUE NOT NULL,
		password_hash TEXT NOT NULL,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP
	)`,
	`CREATE TABLE IF NOT EXISTS playlists (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		user_id INTEGER NOT NULL,
		name TEXT NOT NULL,
		type TEXT NOT NULL CHECK(type IN ('m3u', 'xtream')),
		m3u_url TEXT,
		xtream_server TEXT,
		xtream_username TEXT,
		xtream_password TEXT,
		epg_url TEXT,
		last_refreshed DATETIME,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
	)`,
	`CREATE TABLE IF NOT EXISTS channels (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		playlist_id INTEGER NOT NULL,
		stream_id TEXT,
		name TEXT NOT NULL,
		group_name TEXT,
		stream_url TEXT NOT NULL,
		logo_url TEXT,
		epg_channel_id TEXT,
		sort_order INTEGER DEFAULT 0,
		FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
	)`,
	`CREATE INDEX IF NOT EXISTS idx_channels_playlist ON channels(playlist_id)`,
	`CREATE INDEX IF NOT EXISTS idx_channels_group ON channels(playlist_id, group_name)`,
	`CREATE TABLE IF NOT EXISTS favorite_channels (
		user_id INTEGER NOT NULL,
		channel_id INTEGER NOT NULL,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		PRIMARY KEY(user_id, channel_id),
		FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
		FOREIGN KEY(channel_id) REFERENCES channels(id) ON DELETE CASCADE
	)`,
	`CREATE TABLE IF NOT EXISTS favorite_groups (
		user_id INTEGER NOT NULL,
		playlist_id INTEGER NOT NULL,
		group_name TEXT NOT NULL,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		PRIMARY KEY(user_id, playlist_id, group_name),
		FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
		FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
	)`,
	`CREATE TABLE IF NOT EXISTS epg_cache (
		channel_epg_id TEXT NOT NULL,
		playlist_id INTEGER NOT NULL,
		start_time DATETIME NOT NULL,
		end_time DATETIME NOT NULL,
		title TEXT,
		description TEXT,
		PRIMARY KEY(channel_epg_id, start_time),
		FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
	)`,
	`CREATE TABLE IF NOT EXISTS epg_fetch_log (
		playlist_id INTEGER PRIMARY KEY,
		fetched_at DATETIME NOT NULL,
		FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
	)`,
}
