package database

import (
	"database/sql"
	"log"

	_ "modernc.org/sqlite"
)

var DB *sql.DB

func Init(path string) {
	var err error
	DB, err = sql.Open("sqlite", path)
	if err != nil {
		log.Fatalf("failed to open database: %v", err)
	}

	DB.SetMaxOpenConns(1) // SQLite is single-writer

	if err = DB.Ping(); err != nil {
		log.Fatalf("failed to ping database: %v", err)
	}

	if _, err = DB.Exec(`PRAGMA foreign_keys = ON`); err != nil {
		log.Fatalf("failed to enable foreign_keys pragma: %v", err)
	}

	if _, err = DB.Exec(`PRAGMA busy_timeout = 30000`); err != nil {
		log.Fatalf("failed to set busy_timeout pragma: %v", err)
	}

	migrate()
}

func migrate() {
	// Version tracking table
	if _, err := DB.Exec(`CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY)`); err != nil {
		log.Fatalf("failed to create schema_migrations: %v", err)
	}

	var version int
	DB.QueryRow(`SELECT COALESCE(MAX(version), 0) FROM schema_migrations`).Scan(&version)

	migrations := []struct {
		version int
		stmts   []string
	}{
		{1, []string{
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
		}},
		{2, []string{
			// Recreate playlists with updated CHECK and vuplus columns
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
		}},
		{3, []string{
			// Add m3u_content for file-upload based M3U playlists
			`ALTER TABLE playlists ADD COLUMN m3u_content TEXT`,
		}},
		{4, []string{
			// Repair legacy favorite_groups schema that may reference a non-existent
			// "playlist" table (singular) in older databases.
			`ALTER TABLE favorite_groups RENAME TO favorite_groups_v3`,
			`CREATE TABLE favorite_groups (
				user_id INTEGER NOT NULL,
				playlist_id INTEGER NOT NULL,
				group_name TEXT NOT NULL,
				created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
				PRIMARY KEY(user_id, playlist_id, group_name),
				FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
				FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
			)`,
			`INSERT INTO favorite_groups (user_id, playlist_id, group_name, created_at)
			 SELECT fg.user_id, fg.playlist_id, fg.group_name, fg.created_at
			 FROM favorite_groups_v3 fg
			 JOIN users u ON u.id = fg.user_id
			 JOIN playlists p ON p.id = fg.playlist_id`,
			`DROP TABLE favorite_groups_v3`,
		}},
	}

	for _, m := range migrations {
		if m.version <= version {
			continue
		}
		for _, stmt := range m.stmts {
			if _, err := DB.Exec(stmt); err != nil {
				log.Fatalf("migration v%d failed: %v\nStatement: %s", m.version, err, stmt)
			}
		}
		if _, err := DB.Exec(`INSERT INTO schema_migrations VALUES (?)`, m.version); err != nil {
			log.Fatalf("failed to record migration v%d: %v", m.version, err)
		}
		log.Printf("applied schema migration v%d", m.version)
	}
}
