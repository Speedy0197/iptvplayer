package migrations

// V8 adds one-time TV login sessions used for QR/device-code sign-in.
var V8 = []string{
	`CREATE TABLE IF NOT EXISTS tv_login_sessions (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		device_code_hash TEXT NOT NULL UNIQUE,
		user_code_hash TEXT NOT NULL,
		expires_at DATETIME NOT NULL,
		approved_at DATETIME,
		claimed_at DATETIME,
		approved_user_id INTEGER,
		approved_token TEXT,
		approved_username TEXT,
		approved_email TEXT,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		FOREIGN KEY(approved_user_id) REFERENCES users(id) ON DELETE SET NULL
	)`,
	`CREATE INDEX IF NOT EXISTS idx_tv_login_sessions_expires ON tv_login_sessions(expires_at)`,
}
