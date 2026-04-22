package migrations

// V3 adds m3u_content for file-upload based M3U playlists.
var V3 = []string{
	`ALTER TABLE playlists ADD COLUMN m3u_content TEXT`,
}
