-- node_names lookup + expression index on UPPER(radioId) for upload backfill.
-- Additive draft. Do not apply remotely without approval.
-- CREATE INDEX reads the whole table once (~158k rows).

CREATE TABLE IF NOT EXISTS node_names (
  node_key TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_scans_radioid_upper ON scans(UPPER(radioId));
