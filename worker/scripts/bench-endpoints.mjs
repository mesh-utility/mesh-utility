#!/usr/bin/env node
/**
 * Before/after rows-read bench.
 * BEFORE: run old SQL shapes against local D1 (meta.rows_read).
 * AFTER: curl wrangler-dev endpoints with _debug=1 (X-D1-Rows-Read).
 */
import { spawnSync, spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');
const outPath = path.resolve(root, '../bench-results.json');

function wranglerJson(command) {
  const r = spawnSync(
    'npx',
    ['wrangler', 'd1', 'execute', 'mesh-utility-db-local', '--local', '--json', '--command', command],
    { cwd: root, encoding: 'utf8', maxBuffer: 20 * 1024 * 1024 }
  );
  if (r.status !== 0) {
    console.error(r.stderr || r.stdout);
    throw new Error('wrangler failed');
  }
  const parsed = JSON.parse(r.stdout);
  // wrangler --json returns array of results
  const meta = parsed?.[0]?.meta || parsed?.meta || {};
  const results = parsed?.[0]?.results || parsed?.results || [];
  return { meta, results, raw: parsed };
}

function beforeSql() {
  const distinct = wranglerJson(
    "SELECT DISTINCT date(timestamp / 1000, 'unixepoch') as day FROM scans ORDER BY day DESC"
  );
  const days = distinct.results.map((r) => r.day);
  const seven = days.slice(0, 7);
  const ph = seven.map((d) => `'${d}'`).join(',');
  const coverage7 = seven.length
    ? wranglerJson(
        `SELECT radioId, timestamp, latitude, longitude, nodes FROM scans WHERE date(timestamp / 1000, 'unixepoch') IN (${ph}) ORDER BY timestamp ASC`
      )
    : { meta: { rows_read: 0 }, results: [] };
  // days=0 style — all days (will be huge / may fail)
  let coverageAll = { meta: { rows_read: null }, results: [], error: null };
  try {
    const allPh = days.map((d) => `'${d}'`).join(',');
    coverageAll = wranglerJson(
      `SELECT radioId, timestamp, latitude, longitude, nodes FROM scans WHERE date(timestamp / 1000, 'unixepoch') IN (${allPh}) ORDER BY timestamp ASC`
    );
  } catch (e) {
    coverageAll = { meta: { rows_read: null }, results: [], error: String(e.message || e) };
  }

  const afterDays = wranglerJson('SELECT day FROM scan_days ORDER BY day DESC');
  const range = wranglerJson(
    'SELECT MIN(min_ts) AS min_ts, MAX(max_ts) AS max_ts FROM scan_days'
  );
  const minTs = range.results?.[0]?.min_ts;
  const max7 = afterDays.results.slice(0, 7);
  let cov7new = { meta: { rows_read: 0 }, results: [] };
  if (max7.length) {
    const min7 = wranglerJson(
      `SELECT MIN(min_ts) AS min_ts, MAX(max_ts) AS max_ts FROM scan_days WHERE day IN (${max7.map((d)=>`'${d.day}'`).join(',')})`
    );
    const a = min7.results[0];
    cov7new = wranglerJson(
      `SELECT radioId, timestamp, latitude, longitude, nodes FROM scans WHERE timestamp >= ${a.min_ts} AND timestamp <= ${a.max_ts} ORDER BY timestamp ASC`
    );
  }

  return {
    before: {
      history_distinct_rows_read: distinct.meta.rows_read,
      history_distinct_days: days.length,
      coverage_days7_rows_read: coverage7.meta.rows_read,
      coverage_days7_rows_returned: coverage7.results.length,
      coverage_days0_rows_read: coverageAll.meta.rows_read,
      coverage_days0_error: coverageAll.error,
      coverage_days0_bind_count: days.length,
    },
    sql_after_shapes: {
      history_scan_days_rows_read: afterDays.meta.rows_read,
      history_scan_days_count: afterDays.results.length,
      coverage_days7_timestamp_range_rows_read: cov7new.meta.rows_read,
      coverage_days7_rows_returned: cov7new.results.length,
    },
  };
}

async function afterHttp(base) {
  async function hit(p) {
    const res = await fetch(`${base}${p}`);
    const text = await res.text();
    return {
      status: res.status,
      rowsRead: Number(res.headers.get('x-d1-rows-read') || '0'),
      etag: res.headers.get('etag'),
      bytes: text.length,
      preview: text.slice(0, 120),
      isJsonArray: text.startsWith('['),
    };
  }
  const history = await hit('/history?_debug=1');
  const cov7 = await hit('/coverage?days=7&_debug=1');
  const cov0 = await hit('/coverage?days=0&_debug=1');
  // pick a day from history
  let day = null;
  try {
    const days = JSON.parse((await fetch(`${base}/history`).then((r) => r.text())));
    day = days[0];
  } catch {}
  const histDay = day
    ? await hit(`/history/${day}.ndjson?pageSize=100&_debug=1`)
    : null;
  // 304 check
  const etag = cov7.etag;
  let status304 = null;
  if (etag) {
    const res = await fetch(`${base}/coverage?days=7`, {
      headers: { 'If-None-Match': etag },
    });
    status304 = res.status;
  }
  return { history, coverage_days7: cov7, coverage_days0: cov0, history_day: histDay, coverage_304: status304 };
}

const sqlBench = beforeSql();
console.log('SQL bench', JSON.stringify(sqlBench, null, 2));

// Start wrangler dev
const port = 8787;
const child = spawn(
  'npx',
  ['wrangler', 'dev', '--local', '--ip', '127.0.0.1', '--port', String(port)],
  { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] }
);
let ready = false;
const deadline = Date.now() + 90000;
await new Promise((resolve, reject) => {
  const onData = (buf) => {
    const s = buf.toString();
    process.stdout.write(s);
    if (/Ready on|localhost:8787|127\.0\.0\.1:8787/i.test(s)) {
      ready = true;
      resolve();
    }
  };
  child.stdout.on('data', onData);
  child.stderr.on('data', onData);
  const t = setInterval(() => {
    if (Date.now() > deadline) {
      clearInterval(t);
      reject(new Error('wrangler dev timeout'));
    }
  }, 1000);
});

await new Promise((r) => setTimeout(r, 1500));
let httpBench;
try {
  httpBench = await afterHttp(`http://127.0.0.1:${port}`);
} finally {
  child.kill('SIGTERM');
}

const out = { ...sqlBench, http_after: httpBench, at: new Date().toISOString() };
writeFileSync(outPath, JSON.stringify(out, null, 2));
console.log('Wrote', outPath);
console.log(JSON.stringify(httpBench, null, 2));
