-- Indexed per-hex coverage detail (full Alpha-24 fields) plus per-UTC-day child rows.
-- Additive only. Does not alter or drop hex_facts / coverage_tiles / scans.
-- hex_id is the fixed scale-1 grid id "row:col" (same as lib/src/services/grid.dart hexCellAt).

CREATE TABLE IF NOT EXISTS hex_detail (
  hex_id TEXT PRIMARY KEY,
  row INTEGER NOT NULL,
  col INTEGER NOT NULL,
  scan_count INTEGER NOT NULL,
  first_ts INTEGER NOT NULL,
  last_ts INTEGER NOT NULL,
  best_snr REAL,
  best_rssi REAL,
  last_snr REAL,
  last_rssi REAL,
  last_altitude REAL,
  last_lat REAL NOT NULL,
  last_lng REAL NOT NULL,
  last_node_id TEXT,
  last_node_name TEXT,
  nodes_json TEXT,
  updated_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_hex_detail_row_col ON hex_detail(row, col);
CREATE INDEX IF NOT EXISTS idx_hex_detail_last_ts ON hex_detail(last_ts);

CREATE TABLE IF NOT EXISTS hex_detail_day (
  hex_id TEXT NOT NULL,
  day TEXT NOT NULL,
  row INTEGER NOT NULL,
  col INTEGER NOT NULL,
  scan_count INTEGER NOT NULL,
  first_ts INTEGER NOT NULL,
  last_ts INTEGER NOT NULL,
  best_snr REAL,
  best_rssi REAL,
  last_snr REAL,
  last_rssi REAL,
  last_altitude REAL,
  last_lat REAL NOT NULL,
  last_lng REAL NOT NULL,
  last_node_id TEXT,
  last_node_name TEXT,
  nodes_json TEXT,
  PRIMARY KEY (hex_id, day)
);
CREATE INDEX IF NOT EXISTS idx_hex_detail_day_day ON hex_detail_day(day);
CREATE INDEX IF NOT EXISTS idx_hex_detail_day_row_col_day ON hex_detail_day(row, col, day);
CREATE INDEX IF NOT EXISTS idx_hex_detail_day_last_ts ON hex_detail_day(last_ts);

CREATE TABLE IF NOT EXISTS hex_detail_backfill (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  last_scan_id INTEGER NOT NULL DEFAULT 0,
  last_ts INTEGER NOT NULL DEFAULT 0,
  rows_applied INTEGER NOT NULL DEFAULT 0,
  updated_ms INTEGER NOT NULL
);
