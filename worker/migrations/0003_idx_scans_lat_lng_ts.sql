-- Area queries filter latitude, then longitude, inside a timestamp window.
-- Additive. Do not apply on the production free tier until a low-traffic window:
-- CREATE INDEX reads the table and can spend the daily rows-read budget.
CREATE INDEX IF NOT EXISTS idx_scans_lat_lng_ts ON scans (latitude, longitude, timestamp);
