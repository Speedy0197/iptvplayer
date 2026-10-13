package migrations

// V9 separates short-lived approval links from the private TV polling code.
// Existing sessions retain their password/code approval path.
var V9 = []string{
	`ALTER TABLE tv_login_sessions ADD COLUMN pairing_token TEXT`,
	`ALTER TABLE tv_login_sessions ADD COLUMN pairing_token_hash TEXT`,
	`ALTER TABLE tv_login_sessions ADD COLUMN user_code TEXT`,
	`ALTER TABLE tv_login_sessions ADD COLUMN device_name TEXT NOT NULL DEFAULT 'StreamPilot TV'`,
	`ALTER TABLE tv_login_sessions ADD COLUMN declined_at DATETIME`,
	`CREATE UNIQUE INDEX idx_tv_pairing_token ON tv_login_sessions(pairing_token_hash) WHERE pairing_token_hash IS NOT NULL`,
	`CREATE UNIQUE INDEX idx_tv_user_code ON tv_login_sessions(user_code) WHERE user_code IS NOT NULL`,
}
