-- Keep the frequently refreshed dashboard O(1), and index physical lookups even
-- during the short legacy Worker handoff where empty placeholder keys exist.
CREATE INDEX chunks_blob_lookup ON chunks(blob_key);
CREATE TABLE cache_usage (user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE, bytes INTEGER NOT NULL DEFAULT 0, objects INTEGER NOT NULL DEFAULT 0);
INSERT INTO cache_usage SELECT user_id,COALESCE(SUM(bytes),0),COUNT(*) FROM chunks GROUP BY user_id;
CREATE TRIGGER cache_insert AFTER INSERT ON chunks BEGIN
  INSERT INTO cache_usage(user_id,bytes,objects) VALUES(NEW.user_id,NEW.bytes,1)
  ON CONFLICT(user_id) DO UPDATE SET bytes=bytes+NEW.bytes,objects=objects+1;
END;
CREATE TRIGGER cache_update AFTER UPDATE OF bytes ON chunks BEGIN
  UPDATE cache_usage SET bytes=bytes+NEW.bytes-OLD.bytes WHERE user_id=NEW.user_id;
END;
CREATE TRIGGER cache_delete AFTER DELETE ON chunks BEGIN
  UPDATE cache_usage SET bytes=bytes-OLD.bytes,objects=objects-1 WHERE user_id=OLD.user_id;
END;
CREATE TABLE storage_maintenance (name TEXT PRIMARY KEY,cursor TEXT,complete INTEGER NOT NULL DEFAULT 0);
INSERT INTO storage_maintenance(name) VALUES('legacy-reconciliation');
