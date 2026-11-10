#!/usr/bin/env node
/**
 * Backfill hex_detail + hex_detail_day from scans.
 *
 * Default is dry-run. Writes go to LOCAL D1 unless --remote is also passed
 * with --apply. Remote read-only SELECTs are allowed with --read-remote.
 *
 * Usage (from worker/):
 *   node --experimental-strip-types --import ./scripts/register-ts-ext.mjs \
 *     scripts/backfill-hex-detail.mjs [--apply] [--local|--remote] [--batch=200]
 *   node ... scripts/backfill-hex-detail.mjs --read-remote --export-sample=./tmp-sample.sql --sample-limit=3000
 */
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import {
  applyScanToStore,
  createMemoryHexStore,
  fieldsToRow,
  mergeDetail,
  rowToFields,
  utcDayFromTs,
} from '../src/hex_detail.ts';

const args = new Set(process.argv.slice(2));
const apply = args.has('--apply');
const wantRemoteWrite = args.has('--remote');
const wantLocalWrite = args.has('--local') || (!wantRemoteWrite && apply);
const readRemote = args.has('--read-remote') || wantRemoteWrite;
const reset = args.has('--reset');
const batchArg = [...args].find((a) => a.startsWith('--batch='));
const batchSize = batchArg ? Math.max(20, Number(batchArg.split('=')[1]) || 200) : 200;
const sampleArg = [...args].find((a) => a.startsWith('--export-sample='));
const samplePath = sampleArg ? sampleArg.split('=')[1] : null;
const limitArg = [...args].find((a) => a.startsWith('--sample-limit='));
const sampleLimit = limitArg ? Number(limitArg.split('=')[1]) : 3000;

if (apply && wantRemoteWrite && !process.env.ALLOW_REMOTE_HEX_DETAIL_BACKFILL) {
  // Caller must set this so a typo cannot write prod. The approved remote
  // run sets ALLOW_REMOTE_HEX_DETAIL_BACKFILL=1 in the same command.
  console.error('Refusing --apply --remote without ALLOW_REMOTE_HEX_DETAIL_BACKFILL=1');
  process.exit(2);
}

function wranglerJson(commandSql, { file, remote } = {}) {
  const useRemote = remote ?? readRemote;
  const cmd = ['npx', 'wrangler', 'd1', 'execute', 'mesh-utility-db', '--json'];
  if (useRemote) cmd.push('--remote');
  else cmd.push('--local');
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

const writeTargetRemote = apply && wantRemoteWrite;
console.log(JSON.stringify({
  mode: apply ? (writeTargetRemote ? 'apply-remote' : 'apply-local') : (readRemote ? 'dry-run-remote-read' : 'dry-run-local'),
  batchSize,
  reset,
  samplePath,
  sampleLimit,
}));

const countParsed = wranglerJson('SELECT COUNT(*) AS n, MIN(id) AS min_id, MAX(id) AS max_id, MIN(timestamp) AS min_ts, MAX(timestamp) AS max_ts FROM scans;');
const { rows: countRows, meta: countMeta } = resultsOf(countParsed);
console.log('scans_table', countRows[0], 'meta_rows_read', countMeta.rows_read);

if (samplePath) {
  const limit = Math.max(1, sampleLimit || 3000);
  const pull = wranglerJson(
    `SELECT id, radioId, timestamp, latitude, longitude, altitude, nodes, committed
     FROM scans ORDER BY id ASC LIMIT ${limit};`,
    { remote: readRemote }
  );
  const { rows } = resultsOf(pull);
  const lines = [
    '-- Real scan sample exported with a read-only SELECT. No fake rows.',
    'DELETE FROM scans;',
    'DELETE FROM hex_detail;',
    'DELETE FROM hex_detail_day;',
    'DELETE FROM hex_detail_backfill;',
  ];
  for (const row of rows) {
    const alt = row.altitude == null || row.altitude === '' ? 'NULL' : Number(row.altitude);
    lines.push(
      `INSERT INTO scans (id, radioId, timestamp, latitude, longitude, altitude, nodes, committed) VALUES (${Number(row.id)}, ${sqlLiteral(row.radioId)}, ${Number(row.timestamp)}, ${Number(row.latitude)}, ${Number(row.longitude)}, ${alt}, ${sqlLiteral(row.nodes)}, ${Number(row.committed || 0)});`
    );
  }
  const out = resolve(samplePath);
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, lines.join('\n') + '\n');
  console.log(JSON.stringify({ exported: rows.length, path: out }));
  if (!apply) process.exit(0);
}

if (!apply) {
  if (readRemote) {
    const hexEst = wranglerJson(`SELECT COUNT(*) AS hex_groups FROM (
      SELECT 1 FROM scans GROUP BY
        CAST(ROUND(latitude / ${0.0007 * 1.5}) AS INTEGER),
        CAST(ROUND((longitude - CASE WHEN (ABS(CAST(ROUND(latitude / ${0.0007 * 1.5}) AS INTEGER)) % 2) = 1 THEN ${(0.0007 * 1.7320508075688772 * 1.2) / 2} ELSE 0 END) / ${0.0007 * 1.7320508075688772 * 1.2}) AS INTEGER)
    );`);
    console.log('hex_groups_est', resultsOf(hexEst).rows[0]);
  }
  console.log('Dry-run complete. Re-run with --apply --local (or approved --apply --remote) to write.');
  process.exit(0);
}

const writeRemoteFlag = writeTargetRemote;
function writeJson(sql, opts = {}) {
  return wranglerJson(sql, { ...opts, remote: writeRemoteFlag });
}

writeJson(`CREATE TABLE IF NOT EXISTS hex_detail_backfill (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  last_scan_id INTEGER NOT NULL DEFAULT 0,
  last_ts INTEGER NOT NULL DEFAULT 0,
  rows_applied INTEGER NOT NULL DEFAULT 0,
  updated_ms INTEGER NOT NULL
);`);

if (reset) {
  writeJson(`DELETE FROM hex_detail; DELETE FROM hex_detail_day; DELETE FROM hex_detail_backfill;`);
}

writeJson(`INSERT OR IGNORE INTO hex_detail_backfill (id, last_scan_id, last_ts, rows_applied, updated_ms) VALUES (1, 0, 0, 0, 0);`);
const ck = resultsOf(writeJson(`SELECT last_scan_id, rows_applied FROM hex_detail_backfill WHERE id = 1;`));
let lastId = reset ? 0 : Number(ck.rows[0]?.last_scan_id || 0);
let applied = reset ? 0 : Number(ck.rows[0]?.rows_applied || 0);
console.log('resume_from', { lastId, applied });

const maxId = Number(countRows[0]?.max_id || 0);
while (lastId < maxId) {
  const pull = wranglerJson(
    `SELECT id, radioId, timestamp, latitude, longitude, altitude, nodes
     FROM scans WHERE id > ${lastId} ORDER BY id ASC LIMIT ${batchSize};`,
    { remote: writeRemoteFlag || readRemote }
  );
  const { rows } = resultsOf(pull);
  if (!rows.length) break;
  const store = createMemoryHexStore();
  let batchApplied = 0;
  let maxTs = 0;
  let batchLast = lastId;
  for (const row of rows) {
    const result = applyScanToStore(store, {
      radioId: row.radioId,
      timestamp: Number(row.timestamp),
      latitude: Number(row.latitude),
      longitude: Number(row.longitude),
      altitude: row.altitude,
      nodes: row.nodes,
    }, { dedupe: false });
    if (result.applied) batchApplied += 1;
    batchLast = Number(row.id);
    maxTs = Math.max(maxTs, Number(row.timestamp) || 0);
  }

  const nowMs = Date.now();
  // Merge this batch into existing rows by loading current values would require
  // per-hex reads. Instead upsert via INSERT... then a follow-up merge is
  // handled by applying each store row through ON CONFLICT add. Because a hex
  // can appear in later batches, we merge in SQL for counts/signals and replace
  // last_* when the incoming last_ts is newer. nodes_json is merged here by
  // fetching existing first when the hex already landed.
  const existingIds = [...store.hexes.keys()];
  const existing = new Map();
  if (existingIds.length) {
    for (let i = 0; i < existingIds.length; i += 80) {
      const chunk = existingIds.slice(i, i + 80);
      const inList = chunk.map(sqlLiteral).join(',');
      const got = resultsOf(writeJson(
        `SELECT hex_id, day, scan_count, first_ts, last_ts, best_snr, best_rssi, last_snr, last_rssi, last_altitude, last_lat, last_lng, last_node_id, last_node_name, nodes_json, row, col FROM hex_detail_day WHERE hex_id IN (${inList});`
      ));
      for (const rec of got.rows) existing.set(`${rec.hex_id}|${rec.day}`, rec);
    }
  }
  const dayUpserts = [];
  const hexMerged = new Map();
  for (const [key, fields] of store.days) {
    const day = key.slice(key.lastIndexOf('|') + 1);
    const prev = existing.get(key);
    const merged = prev ? mergeDetail(rowToFields(prev), fields) : fields;
    const r = fieldsToRow(merged, { day, updated_ms: nowMs });
    dayUpserts.push(`(${sqlLiteral(r.hex_id)}, ${sqlLiteral(day)}, ${r.row}, ${r.col}, ${r.scan_count}, ${r.first_ts}, ${r.last_ts}, ${sqlLiteral(r.best_snr)}, ${sqlLiteral(r.best_rssi)}, ${sqlLiteral(r.last_snr)}, ${sqlLiteral(r.last_rssi)}, ${sqlLiteral(r.last_altitude)}, ${r.last_lat}, ${r.last_lng}, ${sqlLiteral(r.last_node_id)}, ${sqlLiteral(r.last_node_name)}, ${sqlLiteral(r.nodes_json)})`);
  }
  const hexExisting = new Map();
  if (existingIds.length) {
    for (let i = 0; i < existingIds.length; i += 80) {
      const chunk = existingIds.slice(i, i + 80);
      const inList = chunk.map(sqlLiteral).join(',');
      const got = resultsOf(writeJson(
        `SELECT hex_id, scan_count, first_ts, last_ts, best_snr, best_rssi, last_snr, last_rssi, last_altitude, last_lat, last_lng, last_node_id, last_node_name, nodes_json, row, col FROM hex_detail WHERE hex_id IN (${inList});`
      ));
      for (const rec of got.rows) hexExisting.set(rec.hex_id, rec);
    }
  }
  const hexUpserts = [];
  for (const [hexId, fields] of store.hexes) {
    const prev = hexExisting.get(hexId);
    const merged = prev ? mergeDetail(rowToFields(prev), fields) : fields;
    hexMerged.set(hexId, merged);
    const r = fieldsToRow(merged, { updated_ms: nowMs });
    hexUpserts.push(`(${sqlLiteral(r.hex_id)}, ${r.row}, ${r.col}, ${r.scan_count}, ${r.first_ts}, ${r.last_ts}, ${sqlLiteral(r.best_snr)}, ${sqlLiteral(r.best_rssi)}, ${sqlLiteral(r.last_snr)}, ${sqlLiteral(r.last_rssi)}, ${sqlLiteral(r.last_altitude)}, ${r.last_lat}, ${r.last_lng}, ${sqlLiteral(r.last_node_id)}, ${sqlLiteral(r.last_node_name)}, ${sqlLiteral(r.nodes_json)}, ${nowMs})`);
  }

  const stmts = [
    ...chunkInserts(`INSERT OR REPLACE INTO hex_detail_day (hex_id, day, row, col, scan_count, first_ts, last_ts, best_snr, best_rssi, last_snr, last_rssi, last_altitude, last_lat, last_lng, last_node_id, last_node_name, nodes_json) VALUES `, dayUpserts),
    ...chunkInserts(`INSERT OR REPLACE INTO hex_detail (hex_id, row, col, scan_count, first_ts, last_ts, best_snr, best_rssi, last_snr, last_rssi, last_altitude, last_lat, last_lng, last_node_id, last_node_name, nodes_json, updated_ms) VALUES `, hexUpserts),
  ];

  applied += batchApplied;
  lastId = batchLast;
  stmts.push(`INSERT OR REPLACE INTO hex_detail_backfill (id, last_scan_id, last_ts, rows_applied, updated_ms) VALUES (1, ${lastId}, ${maxTs}, ${applied}, ${nowMs});`);
  // One file per batch: data + checkpoint commit together, so a crash resumes cleanly.
  const tmp = resolve(new URL('..', import.meta.url).pathname, '.tmp/hex-detail-batch.sql');
  mkdirSync(dirname(tmp), { recursive: true });
  writeFileSync(tmp, stmts.join('\n') + '\n');
  writeJson(null, { file: tmp });
  console.log('batch', { lastId, batchRows: rows.length, applied, hexes: hexUpserts.length, days: dayUpserts.length });
}

const verify = resultsOf(writeJson(`
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
  console.error('Verification failed: hex/day scan sums must equal raw scans count.');
  process.exit(1);
}
console.log(JSON.stringify({ done: true, applied, lastId, verify: v }));
