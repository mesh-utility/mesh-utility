#!/usr/bin/env node
/**
 * Repair hex_detail / hex_detail_day for hexes whose scan_count disagrees
 * with raw scans. Reads all scans (remote read OK), writes only to the
 * requested target. Requires ALLOW_REMOTE_HEX_DETAIL_BACKFILL=1 for --remote.
 */
import { spawnSync } from 'node:child_process';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import {
  applyScanToStore,
  createMemoryHexStore,
  fieldsToRow,
  fineHexAt,
  ROW_SPACING,
  COL_SPACING,
} from '../src/hex_detail.ts';

const args = new Set(process.argv.slice(2));
const apply = args.has('--apply');
const remote = args.has('--remote');
if (apply && remote && !process.env.ALLOW_REMOTE_HEX_DETAIL_BACKFILL) {
  console.error('Refusing --apply --remote without ALLOW_REMOTE_HEX_DETAIL_BACKFILL=1');
  process.exit(2);
}

function wranglerJson(commandSql, { file } = {}) {
  const cmd = ['npx', 'wrangler', 'd1', 'execute', 'mesh-utility-db', '--json'];
  cmd.push(remote ? '--remote' : '--local');
  if (file) cmd.push('--file', file);
  else cmd.push('--command', commandSql);
  const r = spawnSync(cmd[0], cmd.slice(1), {
    cwd: new URL('..', import.meta.url).pathname,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    env: process.env,
  });
  if (r.status !== 0) {
    console.error(r.stderr || r.stdout || 'wrangler failed');
    process.exit(r.status ?? 1);
  }
  const text = (r.stdout || '').trim();
  const start = text.search(/[\[{]/);
  if (start < 0) {
    console.error('No JSON from wrangler:', text.slice(0, 500));
    process.exit(1);
  }
  return JSON.parse(text.slice(start));
}
function resultsOf(parsed) {
  const block = Array.isArray(parsed) ? parsed[0] : parsed;
  return { rows: block.results || [], meta: block.meta || {} };
}
function sqlLiteral(value) {
  if (value == null) return 'NULL';
  if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  return `'${String(value).replace(/'/g, "''")}'`;
}

const rowSpace = ROW_SPACING;
const colSpace = COL_SPACING;
const half = colSpace / 2;
const mismatchSql = `
WITH keyed AS (
  SELECT
    CAST(ROUND(latitude / ${rowSpace}) AS INTEGER) AS row_key,
    CAST(ROUND(
      (longitude - CASE
        WHEN (ABS(CAST(ROUND(latitude / ${rowSpace}) AS INTEGER)) % 2) = 1 THEN ${half}
        ELSE 0
      END) / ${colSpace}
    ) AS INTEGER) AS col_key
  FROM scans
),
expected AS (
  SELECT (row_key || ':' || col_key) AS hex_id, COUNT(*) AS n
  FROM keyed
  GROUP BY row_key, col_key
)
SELECT e.hex_id, e.n AS expected, h.scan_count AS stored
FROM expected e
LEFT JOIN hex_detail h ON h.hex_id = e.hex_id
WHERE h.hex_id IS NULL OR h.scan_count != e.n;
`;

console.log(JSON.stringify({ mode: apply ? (remote ? 'repair-remote' : 'repair-local') : 'dry-run', remote }));
const { rows, meta } = resultsOf(wranglerJson(mismatchSql));
console.log('mismatched_or_missing', rows.length, 'meta_ms', meta.timings?.sql_duration_ms);
const want = new Set(rows.map((r) => String(r.hex_id)));
const expectedTotal = rows.reduce((s, r) => s + Number(r.n || 0), 0);
const storedTotal = rows.reduce((s, r) => s + Number(r.stored || 0), 0);
console.log('repair_expected_sum', expectedTotal, 'repair_stored_sum', storedTotal, 'delta', storedTotal - expectedTotal);
if (!apply) {
  console.log('Dry-run only. Re-run with --apply to rewrite those hexes from raw scans.');
  process.exit(0);
}

const store = createMemoryHexStore();
const { rows: idRows } = resultsOf(wranglerJson('SELECT MAX(id) AS max_id, COUNT(*) AS n FROM scans;'));
const maxId = Number(idRows[0]?.max_id || 0);
let lastId = 0;
let kept = 0;
while (lastId < maxId) {
  const pull = resultsOf(wranglerJson(
    `SELECT id, radioId, timestamp, latitude, longitude, altitude, nodes FROM scans WHERE id > ${lastId} ORDER BY id ASC LIMIT 800;`
  ));
  const batch = pull.rows;
  if (!batch.length) break;
  for (const row of batch) {
    lastId = Number(row.id);
    const cell = fineHexAt(Number(row.latitude), Number(row.longitude));
    if (!want.has(cell.id)) continue;
    applyScanToStore(store, {
      radioId: row.radioId,
      timestamp: Number(row.timestamp),
      latitude: Number(row.latitude),
      longitude: Number(row.longitude),
      altitude: row.altitude,
      nodes: row.nodes,
    }, { dedupe: false });
    kept += 1;
  }
  console.log('scanned_to', lastId, 'kept', kept, 'hexes_built', store.hexes.size);
}

const nowMs = Date.now();
const ids = [...want];
const delChunks = [];
for (let i = 0; i < ids.length; i += 80) {
  const chunk = ids.slice(i, i + 80).map(sqlLiteral).join(',');
  delChunks.push(`DELETE FROM hex_detail_day WHERE hex_id IN (${chunk});`);
  delChunks.push(`DELETE FROM hex_detail WHERE hex_id IN (${chunk});`);
}
const dayUpserts = [];
for (const [key, fields] of store.days) {
  const day = key.slice(key.lastIndexOf('|') + 1);
  const r = fieldsToRow(fields, { day });
  dayUpserts.push(`(${sqlLiteral(r.hex_id)}, ${sqlLiteral(day)}, ${r.row}, ${r.col}, ${r.scan_count}, ${r.first_ts}, ${r.last_ts}, ${sqlLiteral(r.best_snr)}, ${sqlLiteral(r.best_rssi)}, ${sqlLiteral(r.last_snr)}, ${sqlLiteral(r.last_rssi)}, ${sqlLiteral(r.last_altitude)}, ${r.last_lat}, ${r.last_lng}, ${sqlLiteral(r.last_node_id)}, ${sqlLiteral(r.last_node_name)}, ${sqlLiteral(r.nodes_json)})`);
}
const hexUpserts = [];
for (const fields of store.hexes.values()) {
  const r = fieldsToRow(fields, { updated_ms: nowMs });
  hexUpserts.push(`(${sqlLiteral(r.hex_id)}, ${r.row}, ${r.col}, ${r.scan_count}, ${r.first_ts}, ${r.last_ts}, ${sqlLiteral(r.best_snr)}, ${sqlLiteral(r.best_rssi)}, ${sqlLiteral(r.last_snr)}, ${sqlLiteral(r.last_rssi)}, ${sqlLiteral(r.last_altitude)}, ${r.last_lat}, ${r.last_lng}, ${sqlLiteral(r.last_node_id)}, ${sqlLiteral(r.last_node_name)}, ${sqlLiteral(r.nodes_json)}, ${nowMs})`);
}

const STMT_BYTE_CAP = 90_000;
function chunkInserts(prefix, values) {
  const out = [];
  let cur = [];
  let size = prefix.length;
  for (const v of values) {
    if (cur.length && size + v.length + 2 > STMT_BYTE_CAP) {
      out.push(prefix + cur.join(',') + ';');
      cur = [];
      size = prefix.length;
    }
    cur.push(v);
    size += v.length + 1;
  }
  if (cur.length) out.push(prefix + cur.join(',') + ';');
  return out;
}
const stmts = [
  ...delChunks,
  ...chunkInserts(`INSERT OR REPLACE INTO hex_detail_day (hex_id, day, row, col, scan_count, first_ts, last_ts, best_snr, best_rssi, last_snr, last_rssi, last_altitude, last_lat, last_lng, last_node_id, last_node_name, nodes_json) VALUES `, dayUpserts),
  ...chunkInserts(`INSERT OR REPLACE INTO hex_detail (hex_id, row, col, scan_count, first_ts, last_ts, best_snr, best_rssi, last_snr, last_rssi, last_altitude, last_lat, last_lng, last_node_id, last_node_name, nodes_json, updated_ms) VALUES `, hexUpserts),
];
const tmp = resolve(new URL('..', import.meta.url).pathname, '.tmp/hex-detail-repair.sql');
mkdirSync(dirname(tmp), { recursive: true });
writeFileSync(tmp, stmts.join('\n') + '\n');
console.log('writing', stmts.length, 'statements', 'hexes', hexUpserts.length, 'days', dayUpserts.length);
wranglerJson(null, { file: tmp });

const verify = resultsOf(wranglerJson(`
SELECT
  (SELECT COUNT(*) FROM scans) AS scans,
  (SELECT COALESCE(SUM(scan_count),0) FROM hex_detail) AS hex_scan_sum,
  (SELECT COALESCE(SUM(scan_count),0) FROM hex_detail_day) AS day_scan_sum,
  (SELECT COUNT(*) FROM hex_detail) AS hex_rows,
  (SELECT COUNT(*) FROM hex_detail_day) AS day_rows;
`));
const v = verify.rows[0] || {};
const ok = Number(v.scans) === Number(v.hex_scan_sum) && Number(v.scans) === Number(v.day_scan_sum);
console.log('verify', v, 'ok', ok);
if (!ok) {
  console.error('Repair verification failed.');
  process.exit(1);
}
console.log(JSON.stringify({ done: true, repaired: store.hexes.size, kept, verify: v }));
