-- Logical paths (and AES-GCM AAD) stay unchanged. Physical versions are published
-- only after R2 accepts them, with quota held for every in-flight object.
ALTER TABLE users ADD COLUMN privacy_revision INTEGER NOT NULL DEFAULT 0;
ALTER TABLE chunks ADD COLUMN blob_key TEXT NOT NULL DEFAULT '';
ALTER TABLE chunks ADD COLUMN generation INTEGER NOT NULL DEFAULT 1;
ALTER TABLE chunks ADD COLUMN first_day TEXT;
ALTER TABLE chunks ADD COLUMN last_day TEXT;
UPDATE chunks SET generation=(SELECT cache_generation FROM users WHERE id=user_id),
  blob_key=user_id || '/g' || (SELECT cache_generation FROM users WHERE id=user_id) || '/' || substr(object_key,length(user_id)+2);
CREATE UNIQUE INDEX chunks_blob ON chunks(blob_key) WHERE blob_key!='';
CREATE INDEX chunks_coverage ON chunks(user_id,series,first_day,last_day);
CREATE TABLE quota_usage (scope TEXT PRIMARY KEY, bytes INTEGER NOT NULL DEFAULT 0, objects INTEGER NOT NULL DEFAULT 0);
INSERT INTO quota_usage(scope) VALUES('global');
CREATE TABLE storage_objects (
  blob_key TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  generation INTEGER NOT NULL,
  bytes INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('pending','committed','gc'))
);
CREATE INDEX storage_gc ON storage_objects(state,created_at);
CREATE INDEX storage_user ON storage_objects(user_id,generation);
CREATE TRIGGER storage_reserve AFTER INSERT ON storage_objects BEGIN
  UPDATE quota_usage SET bytes=bytes+NEW.bytes,objects=objects+1 WHERE scope='global';
  INSERT INTO quota_usage(scope,bytes,objects) VALUES('user:' || NEW.user_id,NEW.bytes,1)
    ON CONFLICT(scope) DO UPDATE SET bytes=bytes+NEW.bytes,objects=objects+1;
END;
CREATE TRIGGER storage_release AFTER DELETE ON storage_objects BEGIN
  UPDATE quota_usage SET bytes=bytes-OLD.bytes,objects=objects-1 WHERE scope IN ('global','user:' || OLD.user_id);
END;
INSERT INTO storage_objects SELECT blob_key,user_id,generation,bytes,updated_at,'committed' FROM chunks;
ALTER TABLE connections ADD COLUMN generation INTEGER NOT NULL DEFAULT 1;
UPDATE connections SET generation=(SELECT cache_generation FROM users WHERE id=user_id);
CREATE TABLE account_deletions (user_id TEXT PRIMARY KEY, device_pubkey TEXT NOT NULL, deleted_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);
CREATE INDEX deletion_expiry ON account_deletions(expires_at);
CREATE TABLE cache_operations (user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, operation_id TEXT NOT NULL, generation INTEGER NOT NULL, PRIMARY KEY(user_id,operation_id));
ALTER TABLE pairings ADD COLUMN completion_lease TEXT;
ALTER TABLE pairings ADD COLUMN completion_started_at INTEGER;
ALTER TABLE pairings ADD COLUMN completion_attempts INTEGER NOT NULL DEFAULT 0;

CREATE TABLE admission_counters (name TEXT PRIMARY KEY, count INTEGER NOT NULL);

-- Keep the old Worker revision writable during the migration/deploy handoff.
CREATE TRIGGER legacy_chunk_insert AFTER INSERT ON chunks WHEN NEW.blob_key='' BEGIN
  UPDATE chunks SET generation=(SELECT cache_generation FROM users WHERE id=NEW.user_id),
    blob_key=NEW.user_id || '/g' || (SELECT cache_generation FROM users WHERE id=NEW.user_id) || '/' || substr(NEW.object_key,length(NEW.user_id)+2)
    WHERE user_id=NEW.user_id AND object_key=NEW.object_key;
  INSERT OR IGNORE INTO storage_objects SELECT blob_key,user_id,generation,bytes,updated_at,'committed' FROM chunks WHERE user_id=NEW.user_id AND object_key=NEW.object_key;
END;
CREATE TRIGGER legacy_chunk_update AFTER UPDATE OF bytes ON chunks WHEN NEW.blob_key LIKE '%.enc' BEGIN
  UPDATE storage_objects SET bytes=NEW.bytes WHERE blob_key=NEW.blob_key;
END;
CREATE TRIGGER storage_resize AFTER UPDATE OF bytes ON storage_objects BEGIN
  UPDATE quota_usage SET bytes=bytes+NEW.bytes-OLD.bytes WHERE scope IN ('global','user:' || NEW.user_id);
END;
