-- Fine-hex facts + precomputed coverage tiles (true-size scale-1 cells only).
-- Privacy: strength/recency/count buckets only — no radio ids, names, times, positions.

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
