/**
 * SQL and pure helpers for scan-upload D1 work.
 * Keeps radioId case-fix and node-name backfill off full table scans
 * when idx_scans_radioid_upper / node_names / idx_timestamp are present.
 */

export type RadioIdScan = {
  radioId?: unknown;
};

/**
 * Normalized (trim + uppercase) radio ids that still need a legacy-row
 * case fix. Inserts already store the uppercase form, so skip the UPDATE
 * unless at least one incoming raw id differs after trim.
 */
export function radioIdsNeedingCaseFix(scans: ReadonlyArray<RadioIdScan>): string[] {
  const ids: string[] = [];
  const seen = new Set<string>();
  for (const scan of scans) {
    const raw = typeof scan.radioId === 'string' ? scan.radioId.trim() : '';
    if (!raw) continue;
    const normalized = raw.toUpperCase();
    if (raw === normalized) continue;
    if (seen.has(normalized)) continue;
    seen.add(normalized);
    ids.push(normalized);
  }
  return ids;
}

/**
 * Numbered ?1 so SQLite uses idx_scans_radioid_upper.
 * Three independent `?` placeholders plan a table scan even with that index.
 */
export const SQL_UPDATE_RADIO_ID_CASE = `UPDATE scans
SET radioId = ?1
WHERE UPPER(radioId) = ?1
  AND radioId != ?1`;

export const SQL_NODE_NAMES_LOOKUP = `SELECT name FROM node_names WHERE node_key = ?`;

export const SQL_SCANS_NODES_LIKE = `SELECT id, nodes
FROM scans
WHERE nodes LIKE ? ESCAPE '\\'`;

export const SQL_SCANS_NODES_LIKE_BOUNDED = `SELECT id, nodes
FROM scans
WHERE nodes LIKE ? ESCAPE '\\'
  AND timestamp >= ? AND timestamp <= ?`;

export const SQL_NODE_NAMES_UPSERT = `INSERT INTO node_names (node_key, name, updated_at)
VALUES (?, ?, ?)
ON CONFLICT(node_key) DO UPDATE SET
  name = excluded.name,
  updated_at = excluded.updated_at`;
