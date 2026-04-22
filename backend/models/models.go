package models

import "time"

type User struct {
	ID           int64     `json:"id"`
	Username     string    `json:"username"`
	Email        string    `json:"email"`
	PasswordHash string    `json:"-"`
	CreatedAt    time.Time `json:"created_at"`
}

type Playlist struct {
	ID             int64      `json:"id"`
	UserID         int64      `json:"user_id"`
	Name           string     `json:"name"`
	Type           string     `json:"type"` // "m3u", "xtream", or "vuplus"
	M3UURL         *string    `json:"m3u_url,omitempty"`
	M3UContent     *string    `json:"m3u_content,omitempty"`
	XtreamServer   *string    `json:"xtream_server,omitempty"`
	XtreamUsername *string    `json:"xtream_username,omitempty"`
	XtreamPassword *string    `json:"xtream_password,omitempty"`
	VuplusIP       *string    `json:"vuplus_ip,omitempty"`
	VuplusPort     *string    `json:"vuplus_port,omitempty"`
	EpgURL         *string    `json:"epg_url,omitempty"`
	LastRefreshed  *time.Time `json:"last_refreshed,omitempty"`
	CreatedAt      time.Time  `json:"created_at"`
}

type Channel struct {
	ID           int64  `json:"id"`
	PlaylistID   int64  `json:"playlist_id"`
	StreamID     string `json:"stream_id"`
	Name         string `json:"name"`
	GroupName    string `json:"group_name"`
	StreamURL    string `json:"stream_url"`
	LogoURL      string `json:"logo_url"`
	EpgChannelID string `json:"epg_channel_id"`
	SortOrder    int    `json:"sort_order"`
	IsFavorite   bool   `json:"is_favorite"`
}

type Group struct {
	Name         string `json:"name"`
	PlaylistID   int64  `json:"playlist_id"`
	ChannelCount int    `json:"channel_count"`
	IsFavorite   bool   `json:"is_favorite"`
}

type EPGEntry struct {
	ChannelEpgID string    `json:"channel_epg_id"`
	StartTime    time.Time `json:"start_time"`
	EndTime      time.Time `json:"end_time"`
	Title        string    `json:"title"`
	Description  string    `json:"description"`
}
