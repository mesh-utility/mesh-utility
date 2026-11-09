import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import {
  OVERVIEW_CACHE_CONTROL,
  OVERVIEW_CELL_CAP,
  OVERVIEW_FRESH_MS,
  OVERVIEW_HEX_SCALE,
  OVERVIEW_LOOKBACK_DAYS,
  OVERVIEW_STALE_MS,
  aggregateOverviewSamples,
  buildOverviewPayload,
  cellsFromAggRows,
  countBucket,
  overviewAggregateBinds,
  overviewAggregateSql,
  overviewCacheAction,
  overviewCacheKey,
  overviewCellAt,
  overviewCellId,
  recencyBucket,
  roundHalfAwayFromZero,
  serveCoverageOverview,
  strengthBucketFromRatio,
  strengthBucketFromSignal,
} from '../src/coverage_overview.ts';

const NOW = Date.parse('2026-11-09T15:00:00Z');
const DAY = 86_400_000;

const FORBIDDEN_KEYS = new Set([
  'radioid',
  'nodeid',
  'nodename',
  'name',
  'observer',
  'observername',
  'latitude',
  'longitude',
  'lat',
  'lng',
  'lon',
  'timestamp',
  'time',
  'rssi',
  'snr',
  'message',
  'text',
  'nodes',
  'altitude',
  'publickey',
  'scantime',
]);

function assertPublicJson(value, path = '$') {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => assertPublicJson(entry, `${path}[${index}]`));
    return;
  }
  if (value && typeof value === 'object') {
    for (const [key, entry] of Object.entries(value)) {
      assert.equal(
        FORBIDDEN_KEYS.has(key.toLowerCase()),
        false,
        `${path}.${key} is not allowed on the overview payload`,
      );
      assertPublicJson(entry, `${path}.${key}`);
    }
  }
}

function memoryCache(seed) {
  const store = new Map(seed ? [[seed.key, { body: seed.body, storedAtMs: seed.storedAtMs }]] : []);
  return {
    store,
    async match(key) {
      return store.get(key) ?? null;
    },
    async put(key, entry) {
      store.set(key, entry);
    },
  };
}

test('scale-256 cells match the app grid', () => {
  assert.equal(OVERVIEW_HEX_SCALE, 256);
  assert.equal(roundHalfAwayFromZero(-1.5), -2);
  assert.equal(roundHalfAwayFromZero(1.5), 2);
  assert.equal(Math.round(-1.5), -1);
  const stateCollege = overviewCellAt(40.7934, -77.86);
  assert.deepEqual(
    { row: stateCollege.row, col: stateCollege.col },
    { row: 152, col: -209 },
  );
  assert.equal(overviewCellId(stateCollege.row, stateCollege.col), '152:-209');
  assert.equal(stateCollege.centerLat, 40.8576);
  const sameCell = overviewCellAt(40.8, -77.86);
  assert.equal(overviewCellId(sameCell.row, sameCell.col), '152:-209');
  const neutral = overviewCellAt(39.5, -98.35);
  assert.deepEqual({ row: neutral.row, col: neutral.col }, { row: 147, col: -265 });
  const south = overviewCellAt(-40.2, 175.4);
  assert.deepEqual({ row: south.row, col: south.col }, { row: -150, col: 471 });
});

test('SQL groups by the coarse cell and does not select private columns', () => {
  const sql = overviewAggregateSql();
  assert.match(sql, /GROUP BY row_key, col_key/);
  assert.match(sql, /WHERE timestamp >= \?4/);
  assert.match(sql, /LIMIT \?5/);
  assert.match(sql, /IFNULL\(CAST\(json_extract\(nodes/);
  assert.doesNotMatch(sql, /MAX\(CAST\(json_extract/);
  assert.doesNotMatch(sql, /radioId|nodeId|observer|nodeName|publicKey/i);
  const outer = sql.slice(0, sql.indexOf('FROM ('));
  assert.doesNotMatch(outer, /latitude|longitude/);
  const binds = overviewAggregateBinds(NOW);
  assert.equal(binds.length, 5);
  assert.equal(binds[3], NOW - OVERVIEW_LOOKBACK_DAYS * DAY);
  assert.equal(OVERVIEW_LOOKBACK_DAYS, 90);
  assert.equal(binds[4], OVERVIEW_CELL_CAP + 1);
  const gridCell = overviewCellAt(40.7934, -77.86);
  const rowSpace = binds[0];
  const halfCol = binds[1];
  const colSpace = binds[2];
  const row = roundHalfAwayFromZero(40.7934 / rowSpace);
  const offset = Math.abs(row) % 2 === 1 ? halfCol : 0;
  const col = roundHalfAwayFromZero((-77.86 - offset) / colSpace);
  assert.equal(row, gridCell.row);
  assert.equal(col, gridCell.col);
});

test('strength, recency, and count buckets', () => {
  assert.equal(strengthBucketFromSignal(null, null), null);
  assert.equal(strengthBucketFromSignal(-80, 12), 4);
  assert.equal(strengthBucketFromSignal(-95, 5), 4);
  assert.equal(strengthBucketFromSignal(-105, -3), 3);
  assert.equal(strengthBucketFromSignal(-112, -10), 2);
  assert.equal(strengthBucketFromSignal(-120, -20), 1);
  assert.equal(strengthBucketFromSignal(-80, -20), 1);
  assert.equal(strengthBucketFromRatio(0, 10), 0);
  assert.equal(strengthBucketFromRatio(1, 10), 1);
  assert.equal(strengthBucketFromRatio(3, 10), 2);
  assert.equal(strengthBucketFromRatio(6, 10), 3);
  assert.equal(strengthBucketFromRatio(8, 10), 4);

  assert.equal(recencyBucket(Date.parse('2026-11-02T00:00:00Z'), NOW), 0);
  assert.equal(recencyBucket(Date.parse('2026-11-01T23:00:00Z'), NOW), 1);
  assert.equal(recencyBucket(Date.parse('2026-10-10T00:00:00Z'), NOW), 1);
  assert.equal(recencyBucket(Date.parse('2026-10-09T00:00:00Z'), NOW), 2);

  assert.equal(countBucket(1), 0);
  assert.equal(countBucket(9), 1);
  assert.equal(countBucket(10), 2);
  assert.equal(countBucket(99), 2);
  assert.equal(countBucket(100), 3);
  assert.equal(countBucket(999), 3);
  assert.equal(countBucket(1000), 4);
});

test('aggregation merges a cell and drops private fields', () => {
  const cells = aggregateOverviewSamples(
    [
      { latitude: 40.7934, longitude: -77.86, timestamp: NOW - DAY, rssi: -120, snr: -20 },
      { latitude: 40.8, longitude: -77.86, timestamp: NOW - 2 * DAY, rssi: -80, snr: 12 },
      { latitude: 39.5, longitude: -98.35, timestamp: NOW - 40 * DAY, rssi: null, snr: null },
    ],
    NOW,
  );
  assert.equal(cells.length, 2);
  const strong = cells.find((cell) => cell.id === '152:-209');
  const dead = cells.find((cell) => cell.id === '147:-265');
  assert.ok(strong);
  assert.equal(strong.s, 4);
  assert.equal(strong.r, 0);
  assert.equal(strong.n, 1);
  assert.ok(dead);
  assert.equal(dead.s, 0);
  assert.equal(dead.r, 2);
  assert.equal(dead.n, 0);

  const leaked = cellsFromAggRows(
    [
      {
        row_key: 152,
        col_key: -209,
        max_ts: NOW,
        n: 4,
        heard: 4,
        best_rssi: -95,
        best_snr: 6,
        radioId: 'AABBCCDD',
        latitude: 40.7934,
        longitude: -77.86,
        nodeId: '00112233',
        name: 'Tower',
        timestamp: NOW,
      },
    ],
    NOW,
  );
  const payload = buildOverviewPayload(
    [
      {
        row_key: 152,
        col_key: -209,
        max_ts: NOW,
        n: 4,
        heard: 4,
        best_rssi: -95,
        best_snr: 6,
        radioId: 'AABBCCDD',
        latitude: 40.8,
        name: 'Tower',
      },
    ],
    NOW,
  );
  const parsed = JSON.parse(payload.body);
  assert.equal(parsed.generatedDay, '2026-11-09');
  assert.equal(parsed.scale, 256);
  assert.deepEqual(parsed.cells, leaked.cells);
  assert.deepEqual(Object.keys(parsed.cells[0]).sort(), ['id', 'n', 'r', 's']);
  assert.match(parsed.cells[0].id, /^-?\d+:-?\d+$/);
  assertPublicJson(parsed);
  assert.equal(payload.body.includes('\n'), false);
  assert.equal(payload.body.includes('AABBCCDD'), false);
  assert.equal(payload.body.includes('Tower'), false);
  assert.equal(payload.body.includes('40.7934'), false);
});

test('the cell cap keeps the newest rows and sets truncated', () => {
  const rows = [
    { row_key: 1, col_key: 1, max_ts: NOW, n: 1, heard: 1, best_rssi: -80, best_snr: 12 },
    { row_key: 2, col_key: 2, max_ts: NOW - DAY, n: 1, heard: 1, best_rssi: -80, best_snr: 12 },
    { row_key: 3, col_key: 3, max_ts: NOW - 2 * DAY, n: 1, heard: 0, best_rssi: null, best_snr: null },
  ];
  const built = cellsFromAggRows(rows, NOW, 2);
  assert.equal(built.truncated, true);
  assert.deepEqual(built.cells.map((cell) => cell.id), ['1:1', '2:2']);
  const payload = buildOverviewPayload(rows, NOW, 2);
  assert.equal(JSON.parse(payload.body).truncated, true);
});

test('cache key ignores the query string', () => {
  const a = overviewCacheKey('https://mesh.example/coverage/overview?days=9999&lat=1');
  const b = overviewCacheKey('https://mesh.example/api/coverage/overview');
  assert.equal(a, 'https://mesh.example/coverage/overview');
  assert.equal(b, a);
});

test('cache actions: fresh, stale, and expired', () => {
  assert.equal(overviewCacheAction(null), 'miss');
  assert.equal(overviewCacheAction(0), 'fresh');
  assert.equal(overviewCacheAction(OVERVIEW_FRESH_MS - 1), 'fresh');
  assert.equal(overviewCacheAction(OVERVIEW_FRESH_MS), 'stale');
  assert.equal(overviewCacheAction(OVERVIEW_FRESH_MS + OVERVIEW_STALE_MS - 1), 'stale');
  assert.equal(overviewCacheAction(OVERVIEW_FRESH_MS + OVERVIEW_STALE_MS), 'miss');
  assert.equal(OVERVIEW_CACHE_CONTROL, 'public, max-age=3600, stale-while-revalidate=86400');
});

test('a fresh cache hit does not touch D1 and sets cache headers', async () => {
  const body = buildOverviewPayload(
    [{ row_key: 10, col_key: -4, max_ts: NOW, n: 2, heard: 2, best_rssi: -88, best_snr: 8 }],
    NOW,
  ).body;
  const key = overviewCacheKey('https://mesh.example/coverage/overview?days=1');
  const cache = memoryCache({ key, body, storedAtMs: NOW - 1_000 });
  let calls = 0;
  const response = await serveCoverageOverview({
    nowMs: NOW,
    corsHeaders: { 'Access-Control-Allow-Origin': '*' },
    cache,
    cacheKey: key,
    loadRows: async () => {
      calls += 1;
      throw new Error('D1 should not be read');
    },
  });
  assert.equal(calls, 0);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Cache-Control'), OVERVIEW_CACHE_CONTROL);
  assert.equal(response.headers.get('Content-Type'), 'application/json');
  assert.equal(response.headers.get('X-Cached-At'), null);
  const parsed = JSON.parse(await response.text());
  assertPublicJson(parsed);
  assert.equal(parsed.cells[0].id, '10:-4');
});

test('a fresh hit with If-None-Match returns 304 without D1', async () => {
  const body = buildOverviewPayload([], NOW).body;
  const key = overviewCacheKey('https://mesh.example/coverage/overview');
  const cache = memoryCache({ key, body, storedAtMs: NOW - 5_000 });
  const first = await serveCoverageOverview({
    nowMs: NOW,
    corsHeaders: {},
    cache,
    cacheKey: key,
    loadRows: async () => {
      throw new Error('D1 should not be read');
    },
  });
  const etag = first.headers.get('ETag');
  assert.ok(etag);
  const second = await serveCoverageOverview({
    nowMs: NOW,
    corsHeaders: {},
    cache,
    cacheKey: key,
    ifNoneMatch: etag,
    loadRows: async () => {
      throw new Error('D1 should not be read');
    },
  });
  assert.equal(second.status, 304);
  assert.equal(second.headers.get('Cache-Control'), OVERVIEW_CACHE_CONTROL);
  assert.equal(await second.text(), '');
});

test('a stale hit is served immediately and refreshed with waitUntil', async () => {
  const oldBody = JSON.stringify({
    generatedDay: '2026-11-08',
    scale: 256,
    cells: [{ id: '1:1', s: 1, r: 2, n: 0 }],
  });
  const key = overviewCacheKey('https://mesh.example/coverage/overview');
  const cache = memoryCache({ key, body: oldBody, storedAtMs: NOW - OVERVIEW_FRESH_MS - 5_000 });
  let release = () => {};
  const gate = new Promise((resolve) => {
    release = () =>
      resolve([
        { row_key: 9, col_key: 9, max_ts: NOW, n: 3, heard: 3, best_rssi: -85, best_snr: 4 },
      ]);
  });
  let calls = 0;
  const pending = [];
  const response = await serveCoverageOverview({
    nowMs: NOW,
    corsHeaders: { 'Access-Control-Allow-Origin': 'https://mesh-utility.org' },
    cache,
    cacheKey: key,
    waitUntil: (promise) => pending.push(promise),
    loadRows: () => {
      calls += 1;
      return gate;
    },
  });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Cache-Control'), OVERVIEW_CACHE_CONTROL);
  assert.equal(await response.text(), oldBody);
  assert.equal(calls, 1);
  assert.equal(cache.store.get(key).body, oldBody);
  release();
  await Promise.all(pending);
  const refreshed = JSON.parse(cache.store.get(key).body);
  assert.equal(refreshed.cells[0].id, '9:9');
  assert.equal(refreshed.generatedDay, '2026-11-09');
  assertPublicJson(refreshed);
  assert.equal(cache.store.get(key).storedAtMs, NOW);
});

test('a cache miss queries once and stores the public payload', async () => {
  const key = overviewCacheKey('https://mesh.example/coverage/overview?ignored=1');
  const cache = memoryCache();
  let calls = 0;
  const response = await serveCoverageOverview({
    nowMs: NOW,
    corsHeaders: {},
    cache,
    cacheKey: key,
    loadRows: async () => {
      calls += 1;
      return [
        {
          row_key: '152',
          col_key: '-209',
          max_ts: String(NOW - 10 * DAY),
          n: '12',
          heard: '9',
          best_rssi: '-105',
          best_snr: '-3',
        },
      ];
    },
  });
  assert.equal(calls, 1);
  assert.equal(response.headers.get('Cache-Control'), OVERVIEW_CACHE_CONTROL);
  const parsed = JSON.parse(await response.text());
  assert.equal(parsed.cells[0].id, '152:-209');
  assert.equal(parsed.cells[0].s, 3);
  assert.equal(parsed.cells[0].r, 1);
  assert.equal(parsed.cells[0].n, 2);
  assertPublicJson(parsed);
  assert.equal(cache.store.get(key).body, JSON.stringify(parsed));
});

test('an expired cache entry is a miss', async () => {
  const key = overviewCacheKey('https://mesh.example/coverage/overview');
  const cache = memoryCache({
    key,
    body: '{"generatedDay":"2020-01-01","scale":256,"cells":[]}',
    storedAtMs: NOW - OVERVIEW_FRESH_MS - OVERVIEW_STALE_MS - 1,
  });
  let calls = 0;
  const response = await serveCoverageOverview({
    nowMs: NOW,
    corsHeaders: {},
    cache,
    cacheKey: key,
    loadRows: async () => {
      calls += 1;
      return [];
    },
  });
  assert.equal(calls, 1);
  assert.equal(response.status, 200);
  const parsed = JSON.parse(await response.text());
  assert.equal(parsed.generatedDay, '2026-11-09');
  assert.deepEqual(parsed.cells, []);
});

test('SQL aggregation matches the grid and ignores empty node slots', () => {
  const db = new DatabaseSync(':memory:');
  db.exec(`
    CREATE TABLE scans (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      radioId TEXT NOT NULL,
      timestamp INTEGER NOT NULL,
      latitude REAL NOT NULL,
      longitude REAL NOT NULL,
      altitude REAL,
      nodes TEXT NOT NULL,
      committed INTEGER DEFAULT 0
    );
  `);
  const insert = db.prepare(
    'INSERT INTO scans (radioId, timestamp, latitude, longitude, nodes) VALUES (?, ?, ?, ?, ?)',
  );
  const strongNodes = JSON.stringify([
    { nodeId: 'SYNTH0001', name: 'not-in-output', rssi: -80, snr: 12 },
  ]);
  const weakNodes = JSON.stringify([
    { rssi: -120, snr: -20 },
    { name: 'also-hidden' },
  ]);
  const fairNodes = JSON.stringify([{ rssi: -105, snr: -3 }]);
  insert.run('SYNTH0001', NOW - DAY, 40.7934, -77.86, strongNodes);
  insert.run('SYNTH0001', NOW - 2 * DAY, 40.8, -77.86, weakNodes);
  insert.run('SYNTH0002', NOW - 20 * DAY, 39.5, -98.35, fairNodes);
  insert.run('SYNTH0003', NOW - 60 * DAY, 39.74, -104.99, weakNodes);
  insert.run('SYNTH0004', NOW - 2 * DAY, 30.27, -97.74, '[]');
  insert.run('SYNTH0005', NOW - 200 * DAY, 47.6, -122.3, strongNodes);
  insert.run('SYNTH0006', NOW - 3 * DAY, -40.2, 175.4, strongNodes);

  const binds = overviewAggregateBinds(NOW);
  const rows = db.prepare(overviewAggregateSql()).all(...binds);
  for (const row of rows) {
    assert.deepEqual(Object.keys(row).sort(), [
      'best_rssi',
      'best_snr',
      'col_key',
      'heard',
      'max_ts',
      'n',
      'row_key',
    ]);
  }
  const cells = cellsFromAggRows(rows, NOW).cells;
  const byId = new Map(cells.map((cell) => [cell.id, cell]));
  assert.equal(byId.has('152:-209'), true);
  assert.equal(byId.get('152:-209').s, 4);
  assert.equal(byId.get('152:-209').r, 0);
  assert.equal(byId.get('152:-209').n, 1);
  assert.equal(byId.get('147:-265').s, 3);
  assert.equal(byId.get('147:-265').r, 1);
  const denver = overviewCellAt(39.74, -104.99);
  assert.equal(byId.get(overviewCellId(denver.row, denver.col)).s, 1);
  assert.equal(byId.get(overviewCellId(denver.row, denver.col)).r, 2);
  const austin = overviewCellAt(30.27, -97.74);
  assert.equal(byId.get(overviewCellId(austin.row, austin.col)).s, 0);
  const south = overviewCellAt(-40.2, 175.4);
  assert.equal(byId.get(overviewCellId(south.row, south.col)).s, 4);
  const tooOld = overviewCellAt(47.6, -122.3);
  assert.equal(byId.has(overviewCellId(tooOld.row, tooOld.col)), false);
  const payload = JSON.parse(buildOverviewPayload(rows, NOW).body);
  assertPublicJson(payload);
  assert.equal(JSON.stringify(payload).includes('SYNTH'), false);
  assert.equal(JSON.stringify(payload).includes('not-in-output'), false);
  db.close();
});
