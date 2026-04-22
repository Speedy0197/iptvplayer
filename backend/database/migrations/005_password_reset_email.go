package migrations

// V5 adds email-based auth support and password reset token storage.
var V5 = []string{
	`ALTER TABLE users ADD COLUMN email TEXT`,
	`UPDATE users SET email = lower(trim(username)) WHERE email IS NULL`,
	`CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email_unique ON users(email COLLATE NOCASE)`,
	`CREATE TABLE IF NOT EXISTS password_reset_tokens (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		user_id INTEGER NOT NULL,
		token_hash TEXT NOT NULL,
		expires_at DATETIME NOT NULL,
		used_at DATETIME,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
	)`,
	`CREATE UNIQUE INDEX IF NOT EXISTS idx_password_reset_tokens_hash ON password_reset_tokens(token_hash)`,
	`CREATE INDEX IF NOT EXISTS idx_password_reset_tokens_expires ON password_reset_tokens(expires_at)`,
}
