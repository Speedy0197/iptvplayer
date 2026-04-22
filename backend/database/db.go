package database

import (
	"database/sql"
	"fmt"
	"log"

	"github.com/flodev/iptvplayer/database/migrations"
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
	ensurePlaylistColumns()
	ensurePlaylistForeignKeys()
}

func ensurePlaylistColumns() {
	rows, err := DB.Query(`PRAGMA table_info(playlists)`)
	if err != nil {
		log.Fatalf("failed to inspect playlists table schema: %v", err)
	}
	defer rows.Close()

	existing := map[string]bool{}
	for rows.Next() {
		var cid int
		var name string
		var colType string
		var notNull int
		var defaultValue any
		var pk int
		if err := rows.Scan(&cid, &name, &colType, &notNull, &defaultValue, &pk); err != nil {
			log.Fatalf("failed to scan playlists schema: %v", err)
		}
		existing[name] = true
	}
	if err := rows.Err(); err != nil {
		log.Fatalf("failed to read playlists schema: %v", err)
	}

	required := map[string]string{
		"m3u_content": "TEXT",
		"vuplus_ip":   "TEXT",
		"vuplus_port": "TEXT",
	}

	for col, typ := range required {
		if existing[col] {
			continue
		}
		stmt := fmt.Sprintf("ALTER TABLE playlists ADD COLUMN %s %s", col, typ)
		if _, err := DB.Exec(stmt); err != nil {
			log.Fatalf("failed to add missing playlists column %s: %v", col, err)
		}
		log.Printf("added missing playlists column %s", col)
	}
}

func ensurePlaylistForeignKeys() {
	if tableReferences("channels", "playlists_v1") {
		rebuildChannelsTableWithPlaylistsFK()
	}

	if channelFKTarget := favoriteChannelsForeignKeyTarget(); channelFKTarget != "" && channelFKTarget != "channels" {
		rebuildFavoriteChannelsTableWithChannelsFK(channelFKTarget)
	}

	if tableReferences("epg_cache", "playlists_v1") {
		rebuildEpgCacheTableWithPlaylistsFK()
	}

	if tableReferences("epg_fetch_log", "playlists_v1") {
		rebuildEpgFetchLogTableWithPlaylistsFK()
	}
}

func tableReferences(tableName, referencedTable string) bool {
	rows, err := DB.Query(fmt.Sprintf("PRAGMA foreign_key_list(%s)", tableName))
	if err != nil {
		log.Fatalf("failed to inspect foreign keys for %s: %v", tableName, err)
	}
	defer rows.Close()

	for rows.Next() {
		var id int
		var seq int
		var refTable string
		var fromCol string
		var toCol string
		var onUpdate string
		var onDelete string
		var match string

		if err := rows.Scan(&id, &seq, &refTable, &fromCol, &toCol, &onUpdate, &onDelete, &match); err != nil {
			log.Fatalf("failed to scan foreign key for %s: %v", tableName, err)
		}

		if refTable == referencedTable {
			return true
		}
	}

	if err := rows.Err(); err != nil {
		log.Fatalf("failed reading foreign key list for %s: %v", tableName, err)
	}

	return false
}

func favoriteChannelsForeignKeyTarget() string {
	rows, err := DB.Query("PRAGMA foreign_key_list(favorite_channels)")
	if err != nil {
		log.Fatalf("failed to inspect foreign keys for favorite_channels: %v", err)
	}
	defer rows.Close()

	for rows.Next() {
		var id int
		var seq int
		var refTable string
		var fromCol string
		var toCol string
		var onUpdate string
		var onDelete string
		var match string

		if err := rows.Scan(&id, &seq, &refTable, &fromCol, &toCol, &onUpdate, &onDelete, &match); err != nil {
			log.Fatalf("failed to scan foreign key for favorite_channels: %v", err)
		}

		if fromCol == "channel_id" {
			return refTable
		}
	}

	if err := rows.Err(); err != nil {
		log.Fatalf("failed reading foreign key list for favorite_channels: %v", err)
	}

	return ""
}

func rebuildFavoriteChannelsTableWithChannelsFK(previousTarget string) {
	log.Printf("repairing favorite_channels foreign key reference from %s to channels", previousTarget)

	tx, err := DB.Begin()
	if err != nil {
		log.Fatalf("failed to begin favorite_channels FK repair transaction: %v", err)
	}

	if _, err := tx.Exec(`DROP TABLE IF EXISTS favorite_channels_fk_fix_old`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to clean previous favorite_channels temp table: %v", err)
	}

	if _, err := tx.Exec(`ALTER TABLE favorite_channels RENAME TO favorite_channels_fk_fix_old`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to rename favorite_channels table for FK repair: %v", err)
	}

	if _, err := tx.Exec(`CREATE TABLE favorite_channels (
			user_id INTEGER NOT NULL,
			channel_id INTEGER NOT NULL,
			created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY(user_id, channel_id),
			FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
			FOREIGN KEY(channel_id) REFERENCES channels(id) ON DELETE CASCADE
		)`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to create repaired favorite_channels table: %v", err)
	}

	if _, err := tx.Exec(`INSERT INTO favorite_channels (user_id, channel_id, created_at)
		SELECT fc.user_id, fc.channel_id, fc.created_at
		FROM favorite_channels_fk_fix_old fc
		JOIN users u ON u.id = fc.user_id
		JOIN channels c ON c.id = fc.channel_id`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to copy favorite_channels during FK repair: %v", err)
	}

	if _, err := tx.Exec(`DROP TABLE favorite_channels_fk_fix_old`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to drop old favorite_channels table during FK repair: %v", err)
	}

	if err := tx.Commit(); err != nil {
		tx.Rollback()
		log.Fatalf("failed to commit favorite_channels FK repair: %v", err)
	}
}

func rebuildChannelsTableWithPlaylistsFK() {
	log.Printf("repairing channels foreign key reference from playlists_v1 to playlists")

	tx, err := DB.Begin()
	if err != nil {
		log.Fatalf("failed to begin channels FK repair transaction: %v", err)
	}

	if _, err := tx.Exec(`DROP TABLE IF EXISTS channels_fk_fix_old`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to clean previous channels temp table: %v", err)
	}

	if _, err := tx.Exec(`ALTER TABLE channels RENAME TO channels_fk_fix_old`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to rename channels table for FK repair: %v", err)
	}

	if _, err := tx.Exec(`CREATE TABLE channels (
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
		)`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to create repaired channels table: %v", err)
	}

	if _, err := tx.Exec(`INSERT INTO channels (id, playlist_id, stream_id, name, group_name, stream_url, logo_url, epg_channel_id, sort_order)
		SELECT c.id, c.playlist_id, c.stream_id, c.name, c.group_name, c.stream_url, c.logo_url, c.epg_channel_id, c.sort_order
		FROM channels_fk_fix_old c
		JOIN playlists p ON p.id = c.playlist_id`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to copy channels during FK repair: %v", err)
	}

	if _, err := tx.Exec(`DROP TABLE channels_fk_fix_old`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to drop old channels table during FK repair: %v", err)
	}

	if _, err := tx.Exec(`CREATE INDEX IF NOT EXISTS idx_channels_playlist ON channels(playlist_id)`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to recreate idx_channels_playlist: %v", err)
	}

	if _, err := tx.Exec(`CREATE INDEX IF NOT EXISTS idx_channels_group ON channels(playlist_id, group_name)`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to recreate idx_channels_group: %v", err)
	}

	if err := tx.Commit(); err != nil {
		tx.Rollback()
		log.Fatalf("failed to commit channels FK repair: %v", err)
	}
}

func rebuildEpgCacheTableWithPlaylistsFK() {
	log.Printf("repairing epg_cache foreign key reference from playlists_v1 to playlists")

	tx, err := DB.Begin()
	if err != nil {
		log.Fatalf("failed to begin epg_cache FK repair transaction: %v", err)
	}

	if _, err := tx.Exec(`DROP TABLE IF EXISTS epg_cache_fk_fix_old`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to clean previous epg_cache temp table: %v", err)
	}

	if _, err := tx.Exec(`ALTER TABLE epg_cache RENAME TO epg_cache_fk_fix_old`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to rename epg_cache table for FK repair: %v", err)
	}

	if _, err := tx.Exec(`CREATE TABLE epg_cache (
			channel_epg_id TEXT NOT NULL,
			playlist_id INTEGER NOT NULL,
			start_time DATETIME NOT NULL,
			end_time DATETIME NOT NULL,
			title TEXT,
			description TEXT,
			PRIMARY KEY(channel_epg_id, start_time),
			FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
		)`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to create repaired epg_cache table: %v", err)
	}

	if _, err := tx.Exec(`INSERT INTO epg_cache (channel_epg_id, playlist_id, start_time, end_time, title, description)
		SELECT e.channel_epg_id, e.playlist_id, e.start_time, e.end_time, e.title, e.description
		FROM epg_cache_fk_fix_old e
		JOIN playlists p ON p.id = e.playlist_id`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to copy epg_cache during FK repair: %v", err)
	}

	if _, err := tx.Exec(`DROP TABLE epg_cache_fk_fix_old`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to drop old epg_cache table during FK repair: %v", err)
	}

	if err := tx.Commit(); err != nil {
		tx.Rollback()
		log.Fatalf("failed to commit epg_cache FK repair: %v", err)
	}
}

func rebuildEpgFetchLogTableWithPlaylistsFK() {
	log.Printf("repairing epg_fetch_log foreign key reference from playlists_v1 to playlists")

	tx, err := DB.Begin()
	if err != nil {
		log.Fatalf("failed to begin epg_fetch_log FK repair transaction: %v", err)
	}

	if _, err := tx.Exec(`DROP TABLE IF EXISTS epg_fetch_log_fk_fix_old`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to clean previous epg_fetch_log temp table: %v", err)
	}

	if _, err := tx.Exec(`ALTER TABLE epg_fetch_log RENAME TO epg_fetch_log_fk_fix_old`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to rename epg_fetch_log table for FK repair: %v", err)
	}

	if _, err := tx.Exec(`CREATE TABLE epg_fetch_log (
			playlist_id INTEGER PRIMARY KEY,
			fetched_at DATETIME NOT NULL,
			FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
		)`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to create repaired epg_fetch_log table: %v", err)
	}

	if _, err := tx.Exec(`INSERT INTO epg_fetch_log (playlist_id, fetched_at)
		SELECT e.playlist_id, e.fetched_at
		FROM epg_fetch_log_fk_fix_old e
		JOIN playlists p ON p.id = e.playlist_id`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to copy epg_fetch_log during FK repair: %v", err)
	}

	if _, err := tx.Exec(`DROP TABLE epg_fetch_log_fk_fix_old`); err != nil {
		tx.Rollback()
		log.Fatalf("failed to drop old epg_fetch_log table during FK repair: %v", err)
	}

	if err := tx.Commit(); err != nil {
		tx.Rollback()
		log.Fatalf("failed to commit epg_fetch_log FK repair: %v", err)
	}
}

func migrate() {
	if _, err := DB.Exec(`CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY)`); err != nil {
		log.Fatalf("failed to create schema_migrations: %v", err)
	}

	var version int
	DB.QueryRow(`SELECT COALESCE(MAX(version), 0) FROM schema_migrations`).Scan(&version)

	for _, m := range migrations.All {
		if m.Version <= version {
			continue
		}
		for _, stmt := range m.Stmts {
			if _, err := DB.Exec(stmt); err != nil {
				log.Fatalf("migration v%d failed: %v\nStatement: %s", m.Version, err, stmt)
			}
		}
		if _, err := DB.Exec(`INSERT INTO schema_migrations VALUES (?)`, m.Version); err != nil {
			log.Fatalf("failed to record migration v%d: %v", m.Version, err)
		}
		log.Printf("applied schema migration v%d", m.Version)
	}
}
