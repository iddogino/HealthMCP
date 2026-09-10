-- OAuth tokens retain the provider's hash/encrypted-value format. Unlike KV,
-- the primary D1 database gives issuance and refresh a consistent authority.
CREATE TABLE oauth_state (
  key TEXT PRIMARY KEY,
  value TEXT,
  expires_at INTEGER,
  revision INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX oauth_state_expiration ON oauth_state(expires_at);
