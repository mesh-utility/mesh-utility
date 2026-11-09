import assert from 'node:assert/strict';
import test from 'node:test';
import {
  buildCoverageQueries,
  buildGeoBounds,
  buildHistoryQueries,
  coverageZoneAccepted,
  COVERAGE_ZONE_CAP,
  D1_MAX_BOUND_PARAMETERS,
  mergeHistoryRows,
  parsePolygon,
  parseRadiusMiles,
  planHistoryPage,
  pointInRing,
  prepareAreaQuery,
  resolveGeoBounds,
  roundOutward,
} from '../src/area_query.ts';

const table = {
  'US:US-CA': [32, 42, -124, -114],
  'US:US-NY': [40, 45, -80, -72],
  'FJ:X': [-19, -16, 176, -178],
};

function url(search) {
  return new URL(`https://example.test/history/2026-01-01.ndjson${search}`);
}

test('radius still clamps to 250', () => {
  assert.equal(parseRadiusMiles('800'), 250);
  assert.equal(parseRadiusMiles('250'), 250);
  assert.equal(parseRadiusMiles('10'), 10);
  assert.equal(parseRadiusMiles('0'), null);
  assert.equal(parseRadiusMiles('-4'), null);
  assert.equal(parseRadiusMiles('nope'), null);
  const wide = buildGeoBounds('36', '-115', '800');
  const capped = buildGeoBounds('36', '-115', '250');
  assert.deepEqual(wide, capped);
  const resolved = resolveGeoBounds(url('?lat=36&lng=-115&radiusMiles=800'), table);
  assert.equal(resolved.kind, 'radius');
  assert.deepEqual(resolved.bounds, capped);
  assert.equal(resolved.ranges.length, 1);
});

test('bbox wins over radius', () => {
  const geo = resolveGeoBounds(
    url('?minLat=1&maxLat=2&minLng=3&maxLng=4&lat=10&lng=20&radiusMiles=800'),
    table,
  );
  assert.equal(geo.kind, 'bbox');
  assert.equal(geo.error, undefined);
  assert.deepEqual(geo.bounds, { minLat: 1, maxLat: 2, minLng: 3, maxLng: 4 });
  assert.deepEqual(geo.ranges, [geo.bounds]);
});

test('division union, unknown ids, and the 32 cap', () => {
  const both = resolveGeoBounds(
    url('?division=US:US-CA&division=NOPE&division=US:US-NY'),
    table,
  );
  assert.equal(both.kind, 'division');
  assert.equal(both.empty, undefined);
  assert.equal(both.ranges.length, 2);
  assert.deepEqual(both.ranges[0], { minLat: 32, maxLat: 42, minLng: -124, maxLng: -114 });
  assert.deepEqual(both.ranges[1], { minLat: 40, maxLat: 45, minLng: -80, maxLng: -72 });

  const anti = resolveGeoBounds(url('?division=FJ:X'), table);
  assert.equal(anti.ranges.length, 2);
  assert.equal(anti.ranges[0].minLng, 176);
  assert.equal(anti.ranges[0].maxLng, 180);
  assert.equal(anti.ranges[1].minLng, -180);
  assert.equal(anti.ranges[1].maxLng, -178);

  const none = resolveGeoBounds(url('?division=NOPE&division=ALSO'), table);
  assert.equal(none.empty, true);
  assert.equal(none.ranges, null);
  assert.equal(none.kind, 'division');

  const ids = Array.from({ length: 33 }, (_, i) => `division=X${i}`).join('&');
  const tooMany = resolveGeoBounds(url(`?${ids}`), table);
  assert.equal(tooMany.error.status, 400);
});

test('antimeridian split and swapped latitude', async () => {
  const anti = resolveGeoBounds(url('?minLat=1&maxLat=2&minLng=170&maxLng=-170'), table);
  assert.equal(anti.error, undefined);
  assert.equal(anti.bounds, null);
  assert.equal(anti.ranges.length, 2);
  assert.deepEqual(anti.ranges[0], { minLat: 1, maxLat: 2, minLng: 170, maxLng: 180 });
  assert.deepEqual(anti.ranges[1], { minLat: 1, maxLat: 2, minLng: -180, maxLng: -170 });

  const swapped = resolveGeoBounds(url('?minLat=10&maxLat=1&minLng=0&maxLng=1'), table);
  assert.equal(swapped.error.status, 400);
  assert.match(await swapped.error.text(), /minLat/);

  const span = resolveGeoBounds(url('?minLat=-100&maxLat=81&minLng=0&maxLng=1'), table);
  assert.equal(span.error.status, 400);
  assert.match(await span.error.text(), /span/);
});

test('whole-globe bbox is worldwide unless a radius is also set', async () => {
  const mixed = resolveGeoBounds(
    url('?minLat=-90&maxLat=90&minLng=-180&maxLng=180&radiusMiles=10'),
    table,
  );
  assert.equal(mixed.error.status, 400);

  const open = resolveGeoBounds(url('?minLat=-90&maxLat=90&minLng=-180&maxLng=180'), table);
  assert.equal(open.kind, 'worldwide');
  assert.equal(open.ranges, null);
  assert.equal(open.error, undefined);

  const missing = resolveGeoBounds(url(''), table);
  assert.equal(missing.kind, 'worldwide');
  assert.equal(missing.ranges, null);
});

test('polygon cap and point filter', async () => {
  const points = Array.from({ length: 65 }, () => '0,0').join(',');
  const over = parsePolygon(points);
  assert.equal(over.error.status, 400);
  assert.match(await over.error.text(), /64/);

  const ring = parsePolygon('0,0,10,0,0,10');
  assert.equal(ring.error, undefined);
  assert.equal(ring.ring.length, 3);
  const rows = [
    { lng: 1, lat: 1 },
    { lng: 9, lat: 9 },
  ];
  const kept = rows.filter((row) => pointInRing(row.lng, row.lat, ring.ring));
  assert.equal(kept.length, 1);
  assert.deepEqual(kept[0], { lng: 1, lat: 1 });
  assert.equal(parsePolygon(null).ring, null);
});

test('coverage truncation header condition at 5000 hexes', () => {
  assert.equal(COVERAGE_ZONE_CAP, 5000);
  let count = 0;
  let truncated = false;
  for (let i = 0; i < 5001; i++) {
    const decision = coverageZoneAccepted(count, true, true);
    if (!decision.accept) {
      truncated = decision.truncated;
      break;
    }
    count += 1;
  }
  assert.equal(count, 5000);
  assert.equal(truncated, true);
  assert.equal(coverageZoneAccepted(5000, true, false).accept, true);
  assert.equal(coverageZoneAccepted(5000, false, true).accept, true);
});

test('bbox cache key uses the outward 0.1 degree grid', () => {
  const raw = new URL(
    'https://example.test/coverage?minLat=32.53&maxLat=42.01&minLng=-124.13&maxLng=-114.01&days=7&_debug=1&lat=37&lng=-119&radiusMiles=400',
  );
  const geo = resolveGeoBounds(raw, table);
  const prepared = prepareAreaQuery(raw, geo, true);
  assert.deepEqual(prepared.ranges[0], {
    minLat: 32.5,
    maxLat: 42.1,
    minLng: -124.2,
    maxLng: -114,
  });
  assert.equal(prepared.cacheUrl.searchParams.get('minLat'), '32.5');
  assert.equal(prepared.cacheUrl.searchParams.get('maxLat'), '42.1');
  assert.equal(prepared.cacheUrl.searchParams.get('minLng'), '-124.2');
  assert.equal(prepared.cacheUrl.searchParams.get('maxLng'), '-114.0');
  assert.equal(prepared.cacheUrl.searchParams.get('_debug'), null);
  assert.equal(prepared.cacheUrl.searchParams.get('days'), '7');
  assert.equal(prepared.cacheUrl.searchParams.get('radiusMiles'), '400');

  const onGrid = roundOutward({ minLat: 32.5, maxLat: 42, minLng: -124.1, maxLng: -114 });
  assert.deepEqual(onGrid, { minLat: 32.5, maxLat: 42, minLng: -124.1, maxLng: -114 });

  const radius = prepareAreaQuery(
    new URL('https://example.test/coverage?lat=36&lng=-115&radiusMiles=50'),
    resolveGeoBounds(new URL('https://example.test/coverage?lat=36&lng=-115&radiusMiles=50'), table),
    true,
  );
  assert.equal(radius.cacheUrl, null);
});

test('history byte budget stops between scans and keeps the SQL cursor', () => {
  const budget = planHistoryPage(
    [{ bytes: 600_000 }, { bytes: 600_000 }, { bytes: 10 }],
    false,
    1_000_000,
  );
  assert.deepEqual(budget.emit, [true, false, false]);
  assert.equal(budget.hasMore, true);
  assert.equal(budget.cursorIndex, 0);

  const filtered = planHistoryPage([null, { bytes: 10 }, null], true, 1_000_000);
  assert.deepEqual(filtered.emit, [false, true, false]);
  assert.equal(filtered.hasMore, true);
  assert.equal(filtered.cursorIndex, 2);
});

test('history and coverage SQL stay within the D1 bind cap', () => {
  const one = buildHistoryQueries({
    ranges: [{ minLat: 1, maxLat: 2, minLng: 3, maxLng: 4 }],
    dayStart: 10,
    dayEnd: 20,
    pageSize: 1000,
  });
  assert.equal(one.length, 1);
  assert.deepEqual(one[0].binds, [10, 20, 1, 2, 3, 4, 1001]);
  assert.equal(one[0].sql.includes('UNION ALL'), false);
  assert.match(one[0].sql, /latitude BETWEEN/);

  const cursor = buildHistoryQueries({
    ranges: [{ minLat: 1, maxLat: 2, minLng: 3, maxLng: 4 }],
    dayStart: 10,
    dayEnd: 20,
    pageSize: 1000,
    cursorTimestamp: 15,
    cursorId: 7,
  });
  assert.deepEqual(cursor[0].binds, [10, 20, 1, 2, 3, 4, 15, 15, 7, 1001]);

  const world = buildHistoryQueries({ ranges: null, dayStart: 10, dayEnd: 20, pageSize: 1000 });
  assert.deepEqual(world[0].binds, [10, 20, 1001]);
  assert.equal(world[0].sql.includes('latitude BETWEEN'), false);

  const ranges = Array.from({ length: 40 }, (_, i) => ({
    minLat: 0,
    maxLat: 1,
    minLng: i,
    maxLng: i + 0.5,
  }));
  const chunked = buildHistoryQueries({
    ranges,
    dayStart: 1,
    dayEnd: 2,
    pageSize: 1000,
    cursorTimestamp: 5,
    cursorId: 9,
  });
  assert.ok(chunked.length > 1);
  for (const query of chunked) {
    assert.ok(query.binds.length <= D1_MAX_BOUND_PARAMETERS);
    assert.match(query.sql, /UNION ALL/);
  }

  const coverage = buildCoverageQueries({
    ranges: null,
    minTs: 1,
    maxTs: 2,
  });
  assert.equal(coverage[0].sql.includes('latitude BETWEEN'), false);
  const coverageBox = buildCoverageQueries({
    ranges,
    minTs: 1,
    maxTs: 2,
  });
  for (const query of coverageBox) {
    assert.ok(query.binds.length <= D1_MAX_BOUND_PARAMETERS);
  }
});

test('merge keeps timestamp,id order and drops duplicate ids', () => {
  const merged = mergeHistoryRows(
    [
      [
        { id: 2, timestamp: 20 },
        { id: 1, timestamp: 10 },
      ],
      [
        { id: 1, timestamp: 10 },
        { id: 3, timestamp: 30 },
      ],
    ],
    2,
  );
  assert.equal(merged.hasMore, true);
  assert.deepEqual(
    merged.rows.map((row) => row.id),
    [1, 2],
  );
});

test('shipped division table resolves a state and a county', () => {
  const california = resolveGeoBounds(url('?division=US:US-CA'));
  assert.equal(california.kind, 'division');
  assert.equal(california.empty, undefined);
  assert.ok(california.ranges.length >= 1);
  const box = california.ranges[0];
  assert.ok(box.minLat > 30 && box.minLat < 36, box.minLat);
  assert.ok(box.maxLat > 40 && box.maxLat < 45, box.maxLat);
  assert.ok(box.minLng < -120 && box.minLng > -130, box.minLng);
  assert.ok(box.maxLng < -110 && box.maxLng > -120, box.maxLng);

  const losAngeles = resolveGeoBounds(url('?division=CA:06037'));
  assert.equal(losAngeles.empty, undefined);
  assert.ok(losAngeles.ranges[0].minLat > 32 && losAngeles.ranges[0].maxLat < 36);

  const alaska = resolveGeoBounds(url('?division=US:US-AK'));
  assert.equal(alaska.ranges.length, 2);
  assert.ok(alaska.ranges[0].minLng > 0);
  assert.equal(alaska.ranges[1].minLng, -180);
});
