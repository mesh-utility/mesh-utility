#!/usr/bin/env node
/**
 * Rebuild hex_detail + hex_detail_day from every raw scan (REPLACE, not merge).
 * Collects a name catalog first (ids, 8-char prefixes, observer/radio names)
 * and applies it so historical rows pick up names that arrived later.
 *
 * Default is dry-run. Remote writes require --apply --remote and
 * ALLOW_REMOTE_HEX_DETAIL_BACKFILL=1.
 *
 * Usage (from worker/):
 *   node --experimental-strip-types --import ./scripts/register-ts-ext.mjs \
 *     scripts/rebuild-hex-detail.mjs [--apply] [--remote|--local] [--batch=800]
 */
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import {
  addNameToCatalog,
  applyNameCatalog,
  applyScanToStore,
  createMemoryHexStore,
  emptyNameCatalog,
  fieldsToRow,
  lookupCatalogName,
  usableNodeName,
} from '../src/hex_detail.ts';

const args = new Set(process.argv.slice(2));
const apply = args.has('--apply');
const remote = args.has('--remote');
const batchArg = [...args].find((a) => a.startsWith('--batch='));
const batchSize = batchArg ? Math.max(50, Number(batchArg.split('=')[1]) || 800) : 800;

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

function absorbScanNames(catalog, row) {
  addNameToCatalog(catalog, row.radioId, usableNodeName(row.observerName));
  let nodes = row.nodes;
  if (typeof nodes === 'string') {
    try { nodes = JSON.parse(nodes); } catch { nodes = []; }
  }
  if (!Array.isArray(nodes)) return;
  for (const node of nodes) {
    if (!node || typeof node !== 'object') continue;
    addNameToCatalog(catalog, typeof node.nodeId === 'string' ? node.nodeId : '', usableNodeName(node.name));
    addNameToCatalog(catalog, row.radioId, usableNodeName(node.observerName));
    if (typeof node.observerId === 'string') {
      addNameToCatalog(catalog, node.observerId, usableNodeName(node.observerName));
    }
  }
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

function nodeStats(fieldsList) {
  let withName = 0;
  let observers = 0;
  let observerNamed = 0;
  let nodes = 0;
  for (const fields of fieldsList) {
    for (const n of fields.nodes || []) {
      nodes += 1;
      if (usableNodeName(n.n)) withName += 1;
      if (n.role === 'observer') {
        observers += 1;
        if (usableNodeName(n.n)) observerNamed += 1;
      }
    }
  }
  return { nodes, withName, observers, observerNamed };
}

console.log(JSON.stringify({
  mode: apply ? (remote ? 'rebuild-remote' : 'rebuild-local') : (remote ? 'dry-run-remote' : 'dry-run-local'),
  batchSize,
}));

const { rows: countRows } = resultsOf(wranglerJson(
  'SELECT COUNT(*) AS n, MIN(id) AS min_id, MAX(id) AS max_id FROM scans;'
));
const scanCount = Number(countRows[0]?.n || 0);
const maxId = Number(countRows[0]?.max_id || 0);
console.log('scans_table', countRows[0]);

const store = createMemoryHexStore();
const catalog = emptyNameCatalog();
let lastId = 0;
let applied = 0;
while (lastId < maxId) {
  const { rows } = resultsOf(wranglerJson(
    `SELECT id, radioId, timestamp, latitude, longitude, altitude, nodes
     FROM scans WHERE id > ${lastId} ORDER BY id ASC LIMIT ${batchSize};`
  ));
  if (!rows.length) break;
  for (const row of rows) {
    lastId = Number(row.id);
    absorbScanNames(catalog, row);
    // Count unique scan events (radioId+timestamp+lat+lng). Raw duplicate
    // reingest rows stay in `scans` and are not deleted; they must not
    // inflate hex_detail.scan_count / world payload n / popup Scans.
    const result = applyScanToStore(store, {
      radioId: row.radioId,
      timestamp: Number(row.timestamp),
      latitude: Number(row.latitude),
      longitude: Number(row.longitude),
      altitude: row.altitude,
      nodes: row.nodes,
    });
    if (result.applied) applied += 1;
  }
  console.log('scanned_to', lastId, 'applied', applied, 'hexes', store.hexes.size, 'catalog', catalog.byId.size);
}

for (const [hexId, fields] of store.hexes) {
  store.hexes.set(hexId, applyNameCatalog(fields, catalog));
}
for (const [key, fields] of store.days) {
  store.days.set(key, applyNameCatalog(fields, catalog));
}

const hexStats = nodeStats(store.hexes.values());
const dayStats = nodeStats(store.days.values());
console.log('catalog', { byId: catalog.byId.size, byPrefix: catalog.byPrefix.size });
console.log('hex_node_coverage', hexStats);
console.log('day_node_coverage', dayStats);

if (!apply) {
  console.log('Dry-run complete. Re-run with --apply --remote (and ALLOW_REMOTE_HEX_DETAIL_BACKFILL=1) to replace the index.');
  process.exit(0);
}

const nowMs = Date.now();
const rebuiltIds = [...store.hexes.keys()];
const dayUpserts = [];
for (const [key, fields] of store.days) {
  const day = key.slice(key.lastIndexOf('|') + 1);
  const r = fieldsToRow(fields, { day, updated_ms: nowMs });
  dayUpserts.push(`(${sqlLiteral(r.hex_id)}, ${sqlLiteral(day)}, ${r.row}, ${r.col}, ${r.scan_count}, ${r.first_ts}, ${r.last_ts}, ${sqlLiteral(r.best_snr)}, ${sqlLiteral(r.best_rssi)}, ${sqlLiteral(r.last_snr)}, ${sqlLiteral(r.last_rssi)}, ${sqlLiteral(r.last_altitude)}, ${r.last_lat}, ${r.last_lng}, ${sqlLiteral(r.last_node_id)}, ${sqlLiteral(r.last_node_name)}, ${sqlLiteral(r.nodes_json)})`);
}
const hexUpserts = [];
for (const fields of store.hexes.values()) {
  const r = fieldsToRow(fields, { updated_ms: nowMs });
  hexUpserts.push(`(${sqlLiteral(r.hex_id)}, ${r.row}, ${r.col}, ${r.scan_count}, ${r.first_ts}, ${r.last_ts}, ${sqlLiteral(r.best_snr)}, ${sqlLiteral(r.best_rssi)}, ${sqlLiteral(r.last_snr)}, ${sqlLiteral(r.last_rssi)}, ${sqlLiteral(r.last_altitude)}, ${r.last_lat}, ${r.last_lng}, ${sqlLiteral(r.last_node_id)}, ${sqlLiteral(r.last_node_name)}, ${sqlLiteral(r.nodes_json)}, ${nowMs})`);
}

const stmts = [
  ...chunkInserts(`INSERT OR REPLACE INTO hex_detail_day (hex_id, day, row, col, scan_count, first_ts, last_ts, best_snr, best_rssi, last_snr, last_rssi, last_altitude, last_lat, last_lng, last_node_id, last_node_name, nodes_json) VALUES `, dayUpserts),
  ...chunkInserts(`INSERT OR REPLACE INTO hex_detail (hex_id, row, col, scan_count, first_ts, last_ts, best_snr, best_rssi, last_snr, last_rssi, last_altitude, last_lat, last_lng, last_node_id, last_node_name, nodes_json, updated_ms) VALUES `, hexUpserts),
  `INSERT OR REPLACE INTO hex_detail_backfill (id, last_scan_id, last_ts, rows_applied, updated_ms) VALUES (1, ${lastId}, ${nowMs}, ${applied}, ${nowMs});`,
];
const tmp = resolve(new URL('..', import.meta.url).pathname, '.tmp/hex-detail-rebuild.sql');
mkdirSync(dirname(tmp), { recursive: true });
console.log('writing', stmts.length, 'statements', 'hexes', hexUpserts.length, 'days', dayUpserts.length, 'bytes', stmts.join('\n').length);
// One statement per remote execute. Wrangler multi-statement files have
// previously injected CREATE TEMP / implicit transactions (SQLITE_AUTH).
for (let i = 0; i < stmts.length; i++) {
  writeFileSync(tmp, stmts[i] + '\n');
  wranglerJson(null, { file: tmp });
  if ((i + 1) % 10 === 0 || i + 1 === stmts.length) {
    console.log('wrote', i + 1, '/', stmts.length);
  }
}

const verify = resultsOf(wranglerJson(`
SELECT
  (SELECT COUNT(*) FROM scans) AS scans,
  (SELECT COALESCE(SUM(scan_count),0) FROM hex_detail) AS hex_scan_sum,
  (SELECT COALESCE(SUM(scan_count),0) FROM hex_detail_day) AS day_scan_sum,
  (SELECT COUNT(*) FROM hex_detail) AS hex_rows,
  (SELECT COUNT(*) FROM hex_detail_day) AS day_rows,
  (SELECT MAX(id) FROM scans) AS max_id,
  (SELECT scan_count FROM hex_detail WHERE hex_id = '38944:-53253') AS millheim;
`));
const v = verify.rows[0] || {};
const uniqueEvents = applied;
const ok = Number(v.hex_scan_sum) === uniqueEvents && Number(v.day_scan_sum) === uniqueEvents;
console.log('verify', v, 'ok', ok, 'unique_events', uniqueEvents, 'raw_scan_rows', scanCount, 'extra_duplicate_rows', Number(v.scans) - uniqueEvents);
if (!ok) {
  console.error('Rebuild verification failed: hex/day scan sums must equal unique scan events (radio+ts+lat+lng), not raw row count.');
  process.exit(1);
}

const sample = resultsOf(wranglerJson(`
SELECT
  (SELECT COUNT(*) FROM hex_detail) AS hexes,
  (SELECT COUNT(*) FROM hex_detail WHERE instr(nodes_json, '"role":"observer"') > 0 OR instr(nodes_json, '"role": "observer"') > 0) AS hexes_with_observer,
  (SELECT COUNT(*) FROM hex_detail WHERE last_node_name IS NOT NULL AND last_node_name != '' AND last_node_name != 'Unknown') AS hexes_with_last_name;
`));
console.log('name_sample', sample.rows[0]);
console.log(JSON.stringify({ done: true, applied, lastId, catalog: catalog.byId.size, hexStats, verify: v, name_sample: sample.rows[0] }));
