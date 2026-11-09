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
