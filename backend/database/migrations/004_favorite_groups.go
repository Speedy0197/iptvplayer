package migrations

// V4 repairs legacy favorite_groups schema that may reference a non-existent
// "playlist" table (singular) in older databases.
var V4 = []string{
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
}
