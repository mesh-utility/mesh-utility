-- Summary table of distinct UTC days present in scans (avoids SELECT DISTINCT full scans).
CREATE TABLE IF NOT EXISTS scan_days (
  day TEXT PRIMARY KEY,
  scan_count INTEGER NOT NULL DEFAULT 0,
  min_ts INTEGER,
  max_ts INTEGER
);

CREATE INDEX IF NOT EXISTS idx_scan_days_max_ts ON scan_days(max_ts DESC);
