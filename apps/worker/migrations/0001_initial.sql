PRAGMA foreign_keys = ON;
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  device_pubkey TEXT NOT NULL UNIQUE,
  apns_token TEXT,
  apns_environment TEXT NOT NULL DEFAULT 'production',
  created_at INTEGER NOT NULL,
  last_synced_at INTEGER,
  cache_generation INTEGER NOT NULL DEFAULT 1,
  state TEXT NOT NULL DEFAULT 'active',
  pending_sync_at INTEGER,
  last_visible_push_at INTEGER,
  last_push_status TEXT
);
CREATE TABLE series (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  series TEXT NOT NULL,
  first_day TEXT NOT NULL,
  last_day TEXT NOT NULL,
  total_samples INTEGER NOT NULL DEFAULT 0,
  last_synced_at INTEGER NOT NULL,
  PRIMARY KEY(user_id, series)
);
CREATE TABLE chunks (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  series TEXT NOT NULL,
  period TEXT NOT NULL,
  object_key TEXT NOT NULL,
  bytes INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY(user_id, object_key)
);
CREATE INDEX chunks_lookup ON chunks(user_id, series, period);
CREATE TABLE nonces (
  user_id TEXT NOT NULL,
  nonce TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY(user_id, nonce)
);
CREATE INDEX nonces_expiry ON nonces(expires_at);
CREATE TABLE pairings (
  id TEXT PRIMARY KEY,
  code TEXT NOT NULL UNIQUE,
  browser_hash TEXT NOT NULL,
  oauth_request TEXT NOT NULL,
  client_name TEXT NOT NULL,
  redirect_host TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  user_id TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  redirect_to TEXT
);
CREATE INDEX pairings_expiry ON pairings(expires_at);
CREATE TABLE connections (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  client_id TEXT NOT NULL,
  client_name TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  revoked_at INTEGER
);
CREATE TABLE rate_limits (
  key TEXT PRIMARY KEY,
  count INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX rate_limits_expiry ON rate_limits(expires_at);
