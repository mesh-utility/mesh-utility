-- Mesh Utility D1 Database Schema (local / fresh installs)

CREATE TABLE IF NOT EXISTS scans (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  radioId TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  altitude REAL,
  nodes TEXT NOT NULL,
  committed INTEGER DEFAULT 0,
  createdAt INTEGER DEFAULT (strftime('%s', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_radioId ON scans(radioId);
CREATE INDEX IF NOT EXISTS idx_timestamp ON scans(timestamp);
CREATE INDEX IF NOT EXISTS idx_committed ON scans(committed);
CREATE INDEX IF NOT EXISTS idx_scans_lat_lng_ts ON scans (latitude, longitude, timestamp);

CREATE TABLE IF NOT EXISTS commits (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  commitSha TEXT NOT NULL,
  commitMessage TEXT,
  scanCount INTEGER NOT NULL,
  committedAt INTEGER DEFAULT (strftime('%s', 'now'))
);

CREATE TABLE IF NOT EXISTS scan_days (
  day TEXT PRIMARY KEY,
  scan_count INTEGER NOT NULL DEFAULT 0,
  min_ts INTEGER,
  max_ts INTEGER
);

CREATE INDEX IF NOT EXISTS idx_scan_days_max_ts ON scan_days(max_ts DESC);

-- Full-field hex index (scale-1 row:col). Privacy tile tables were dropped in 0006.
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
