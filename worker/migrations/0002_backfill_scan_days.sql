-- One-time backfill from existing scans. Safe to re-run (REPLACE).
INSERT OR REPLACE INTO scan_days (day, scan_count, min_ts, max_ts)
SELECT
  date(timestamp / 1000, 'unixepoch') AS day,
  COUNT(*) AS scan_count,
  MIN(timestamp) AS min_ts,
  MAX(timestamp) AS max_ts
FROM scans
GROUP BY date(timestamp / 1000, 'unixepoch');
