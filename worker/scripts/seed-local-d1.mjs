#!/usr/bin/env node
/**
 * Seed local D1 from a slice of mesh-data/scans.csv (grouped into scan rows).
 * Local only — never touches remote.
 */
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { createReadStream } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');
const csvPath =
  process.env.SCANS_CSV ||
  path.resolve(root, '../mesh-data/scans.csv');
const maxGroups = Number(process.env.SEED_MAX_GROUPS || 8000);
const outSql = path.resolve(root, '.seed/seed_data.sql');

mkdirSync(path.dirname(outSql), { recursive: true });

function wrangler(args) {
  const r = spawnSync('npx', ['wrangler', ...args], {
    cwd: root,
    encoding: 'utf8',
    maxBuffer: 50 * 1024 * 1024,
  });
  if (r.status !== 0) {
    console.error(r.stdout);
    console.error(r.stderr);
    process.exit(r.status || 1);
  }
  return r.stdout;
}

console.log('Applying schema + migrations locally...');
wrangler(['d1', 'execute', 'mesh-utility-db-local', '--local', '--file', 'schema.sql']);
wrangler([
  'd1',
  'execute',
  'mesh-utility-db-local',
  '--local',
  '--file',
  'migrations/0001_scan_days.sql',
]);

// Clear for idempotent re-seed
wrangler([
  'd1',
  'execute',
  'mesh-utility-db-local',
  '--local',
  '--command',
  'DELETE FROM scans; DELETE FROM scan_days; DELETE FROM sqlite_sequence WHERE name IN ("scans","commits");',
]);

console.log(`Reading CSV ${csvPath} (max ${maxGroups} groups)...`);
const groups = new Map(); // key -> {radioId, timestamp, lat, lng, alt, nodes:[]}
let lineNo = 0;
const rl = createInterface({ input: createReadStream(csvPath), crlfDelay: Infinity });
for await (const line of rl) {
  lineNo++;
  if (lineNo === 1) continue; // header
  if (!line.trim()) continue;
  // CSV: row_id,radioId,timestamp,datetime_utc,latitude,longitude,altitude,nodeId,rssi,snr,observerName,nodeName,snr_repeater_to_observer,snr_observer_to_repeater
  // naive split — fields don't contain commas in practice for this dataset
  const parts = line.split(',');
  if (parts.length < 10) continue;
  const radioId = parts[1];
  const timestamp = Number(parts[2]);
  const latitude = Number(parts[4]);
  const longitude = Number(parts[5]);
  const altitude = parts[6] === '' ? null : Number(parts[6]);
  const nodeId = parts[7] || '';
  const rssi = parts[8] === '' ? null : Number(parts[8]);
  const snr = parts[9] === '' ? null : Number(parts[9]);
  const observerName = parts[10] || undefined;
  const nodeName = parts[11] || undefined;
  if (!radioId || !Number.isFinite(timestamp)) continue;
  const key = `${radioId}|${timestamp}`;
  let g = groups.get(key);
  if (!g) {
    if (groups.size >= maxGroups) {
      // stop reading further new groups but continue filling existing? just break
      break;
    }
    g = { radioId, timestamp, latitude, longitude, altitude, nodes: [] };
    groups.set(key, g);
  }
  if (nodeId) {
    g.nodes.push({
      nodeId,
      name: nodeName || undefined,
      observerName: observerName || undefined,
      rssi: rssi ?? 0,
      snr: snr ?? 0,
    });
  }
}

console.log(`Grouped ${groups.size} scans from ${lineNo} CSV lines`);

const stmts = [];
for (const g of groups.values()) {
  const nodes = JSON.stringify(g.nodes).replace(/'/g, "''");
  const alt = g.altitude == null || Number.isNaN(g.altitude) ? 'NULL' : g.altitude;
  stmts.push(
    `INSERT INTO scans (radioId, timestamp, latitude, longitude, altitude, nodes, committed) VALUES ('${g.radioId.replace(/'/g, "''")}', ${g.timestamp}, ${g.latitude}, ${g.longitude}, ${alt}, '${nodes}', 1);`
  );
}
writeFileSync(outSql, stmts.join('\n') + '\n');
console.log(`Wrote ${stmts.length} inserts -> ${outSql}`);

// Execute in chunks to avoid huge CLI args
const CHUNK = 500;
for (let i = 0; i < stmts.length; i += CHUNK) {
  const chunkFile = path.resolve(root, `.seed/chunk_${i}.sql`);
  writeFileSync(chunkFile, stmts.slice(i, i + CHUNK).join('\n') + '\n');
  wrangler(['d1', 'execute', 'mesh-utility-db-local', '--local', '--file', chunkFile]);
  process.stdout.write(`inserted ${Math.min(i + CHUNK, stmts.length)}/${stmts.length}\r`);
}
console.log('\nBackfilling scan_days...');
wrangler([
  'd1',
  'execute',
  'mesh-utility-db-local',
  '--local',
  '--file',
  'migrations/0002_backfill_scan_days.sql',
]);

const counts = wrangler([
  'd1',
  'execute',
  'mesh-utility-db-local',
  '--local',
  '--command',
  "SELECT 'scans' AS t, COUNT(*) AS n FROM scans UNION ALL SELECT 'scan_days', COUNT(*) FROM scan_days;",
  '--json',
]);
console.log(counts);
console.log('Seed complete.');
