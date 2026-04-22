package database

import (
	"database/sql"

	"github.com/flodev/iptvplayer/models"
)

// ScanChannel scans the standard 10-column channel row into c.
func ScanChannel(rows *sql.Rows, c *models.Channel) error {
	return rows.Scan(&c.ID, &c.PlaylistID, &c.StreamID, &c.Name,
		&c.GroupName, &c.StreamURL, &c.LogoURL, &c.EpgChannelID,
		&c.SortOrder, &c.IsFavorite)
}
