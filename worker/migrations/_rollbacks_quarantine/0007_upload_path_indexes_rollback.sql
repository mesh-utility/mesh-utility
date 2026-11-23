-- Quarantined so `d1 migrations apply` never auto-runs drops.
-- Rolls back migration 0007 only.

DROP INDEX IF EXISTS idx_scans_radioid_upper;
DROP TABLE IF EXISTS node_names;
