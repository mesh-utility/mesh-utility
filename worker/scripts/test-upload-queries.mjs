import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { buildHistoryQueries } from '../src/area_query.ts';
import {
  radioIdsNeedingCaseFix,
  SQL_NODE_NAMES_LOOKUP,
  SQL_SCANS_NODES_LIKE_BOUNDED,
  SQL_UPDATE_RADIO_ID_CASE,
} from '../src/upload_queries.ts';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SCHEMA_SQL = readFileSync(join(ROOT, 'schema.sql'), 'utf8');
const SCAN_COUNT = 20_000;
const BASE_TS = 1_700_000_000;

function planOf(db, sql, ...binds) {
  const rows = db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds);
  return rows.map((row) => String(row.detail)).join('\n');
}

function seedScans(db) {
  const insert = db.prepare(
    `INSERT INTO scans (radioId, timestamp, latitude, longitude, altitude, nodes, committed)
     VALUES (?, ?, ?, ?, ?, ?, 0)`,
  );
  db.exec('BEGIN');
  for (let i = 0; i < SCAN_COUNT; i++) {
    const inSmallBox = i < 200;
    const lat = inSmallBox ? 40.1 + (i % 20) * 0.002 : ((i % 170) - 80);
    const lng = inSmallBox ? -77.1 + (i % 15) * 0.002 : ((i % 350) - 175);
    const radioId = i % 20 === 0 ? 'abcd1234' : 'OTHERID00';
    const nodeId = i % 50 === 0 ? 'AABBCCDD' : 'FF00FF00';
    const nodes = JSON.stringify([{ nodeId, name: nodeId === 'AABBCCDD' ? '' : 'n' }]);
    insert.run(radioId, BASE_TS + i, lat, lng, null, nodes);
  }
  db.exec('COMMIT');
  db.prepare(
    `INSERT INTO node_names (node_key, name, updated_at) VALUES (?, ?, ?)`,
  ).run('AABBCCDD', 'Alpha', BASE_TS);
  db.exec('ANALYZE');
}

test('radioIdsNeedingCaseFix returns [] for uppercase and the id for lowercase', () => {
  assert.deepEqual(radioIdsNeedingCaseFix([{ radioId: 'ABCD1234' }]), []);
  assert.deepEqual(radioIdsNeedingCaseFix([{ radioId: 'abcd1234' }]), ['ABCD1234']);
  assert.deepEqual(
    radioIdsNeedingCaseFix([
      { radioId: 'ABCD1234' },
      { radioId: 'efgh' },
      { radioId: 'EFGH' },
      { radioId: '  ABCD1234  ' },
    ]),
    ['EFGH'],
  );
  assert.deepEqual(radioIdsNeedingCaseFix([]), []);
});

test('upload SQL uses indexes instead of full scans of scans', () => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA_SQL);
  seedScans(db);

  const radioPlan = planOf(db, SQL_UPDATE_RADIO_ID_CASE, 'ABCD1234');
  assert.match(radioPlan, /idx_scans_radioid_upper/);
  assert.doesNotMatch(radioPlan, /SCAN scans/);

  const likePlan = planOf(
    db,
    SQL_SCANS_NODES_LIKE_BOUNDED,
    '%"nodeId":"AABBCCDD%',
    BASE_TS,
    BASE_TS + 100,
  );
  assert.match(likePlan, /idx_timestamp/);
  assert.doesNotMatch(likePlan, /SCAN scans/);

  const lookupPlan = planOf(db, SQL_NODE_NAMES_LOOKUP, 'AABBCCDD');
  assert.match(lookupPlan, /node_key/);
  assert.doesNotMatch(lookupPlan, /SCAN node_names/);

  const smallRange = { minLat: 40, maxLat: 40.5, minLng: -77.5, maxLng: -76.8 };
  const small = buildHistoryQueries({
    ranges: [smallRange],
    dayStart: BASE_TS,
    dayEnd: BASE_TS + SCAN_COUNT,
    pageSize: 1000,
  });
  assert.match(small[0].sql, /\+timestamp >= \? AND \+timestamp <= \?/);
  const smallPlan = planOf(db, small[0].sql, ...small[0].binds);
  assert.match(smallPlan, /idx_scans_lat_lng_ts/);
  assert.doesNotMatch(smallPlan, /idx_timestamp/);

  const large = buildHistoryQueries({
    ranges: [{ minLat: 30, maxLat: 42, minLng: -80, maxLng: -70 }],
    dayStart: BASE_TS,
    dayEnd: BASE_TS + SCAN_COUNT,
    pageSize: 1000,
  });
  assert.equal(large[0].sql.includes('+timestamp'), false);
  assert.match(large[0].sql, /WHERE timestamp >= \? AND timestamp <= \?/);

  const oldSql = small[0].sql.replaceAll('+timestamp', 'timestamp');
  const newRows = db.prepare(small[0].sql).all(...small[0].binds);
  const oldRows = db.prepare(oldSql).all(...small[0].binds);
  assert.deepEqual(
    newRows.map((row) => row.id),
    oldRows.map((row) => row.id),
  );
  assert.ok(newRows.length > 0);

  db.close();
});
