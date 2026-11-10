-- Cannot recreate dropped hex_facts / coverage_tiles data from this file.
-- Restore those tables from the pre-0006 D1 export in /workspace/mesh-utility/backups.
-- Schema-only recreate (empty) is left here for reference:

CREATE TABLE IF NOT EXISTS hex_facts (
  hex_id TEXT PRIMARY KEY,
  strength INTEGER NOT NULL,
  recency INTEGER NOT NULL,
  count_bucket INTEGER NOT NULL,
  updated_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_hex_facts_updated ON hex_facts(updated_ms);

CREATE TABLE IF NOT EXISTS coverage_tiles (
  tile_id TEXT PRIMARY KEY,
  etag TEXT NOT NULL,
  body TEXT NOT NULL,
  updated_ms INTEGER NOT NULL,
  cell_count INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_coverage_tiles_updated ON coverage_tiles(updated_ms);
