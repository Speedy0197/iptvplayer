package migrations

// V7 adds source-key favorites for frontend-fetched channels.
var V7 = []string{
	`CREATE TABLE IF NOT EXISTS favorite_channel_sources (
		user_id INTEGER NOT NULL,
		playlist_id INTEGER NOT NULL,
		stream_id TEXT NOT NULL,
		name TEXT NOT NULL DEFAULT '',
		group_name TEXT NOT NULL DEFAULT 'Uncategorized',
		stream_url TEXT NOT NULL DEFAULT '',
		logo_url TEXT NOT NULL DEFAULT '',
		epg_channel_id TEXT NOT NULL DEFAULT '',
		sort_order INTEGER NOT NULL DEFAULT 0,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		PRIMARY KEY(user_id, playlist_id, stream_id),
		FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
		FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
	)`,
	`CREATE INDEX IF NOT EXISTS idx_favorite_channel_sources_user_created ON favorite_channel_sources(user_id, created_at DESC)`,
}
