-- Mesh Utility D1 Database Schema
-- Stores scan data temporarily before committing to GitHub

CREATE TABLE IF NOT EXISTS scans (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  radioId TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  altitude REAL,
  nodes TEXT NOT NULL, -- JSON array of detected nodes
  committed INTEGER DEFAULT 0, -- 0 = pending, 1 = committed to GitHub
  createdAt INTEGER DEFAULT (strftime('%s', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_radioId ON scans(radioId);
CREATE INDEX IF NOT EXISTS idx_timestamp ON scans(timestamp);
CREATE INDEX IF NOT EXISTS idx_committed ON scans(committed);

CREATE TABLE IF NOT EXISTS commits (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  commitSha TEXT NOT NULL,
  commitMessage TEXT,
  scanCount INTEGER NOT NULL,
  committedAt INTEGER DEFAULT (strftime('%s', 'now'))
);
