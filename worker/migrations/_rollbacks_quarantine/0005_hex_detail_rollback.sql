-- Quarantined so `d1 migrations apply` never auto-runs drops.
-- Rolls back migration 0005 only (leaves hex_facts / coverage_tiles / scans alone).

DROP TABLE IF EXISTS hex_detail_backfill;
DROP TABLE IF EXISTS hex_detail_day;
DROP TABLE IF EXISTS hex_detail;
