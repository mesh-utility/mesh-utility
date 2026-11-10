import assert from 'node:assert/strict';
import test from 'node:test';
import {
  hexCellCenter,
  nodesFromScan,
  ROW_SPACING,
  addNameToCatalog,
  applyNameCatalog,
  applyScanToHexDetail,
  applyScanToStore,
  aggregateStoreForDays,
  buildHexDetailPayload,
  buildHexListPayload,
  createMemoryHexStore,
  emptyNameCatalog,
  existingScanSelectSql,
  extractHexIdFromPath,
  fineHexAt,
  hexIdFor,
  isPlaceholderNodeName,
  lookupCatalogName,
  mergeDetail,
  mergeHexNodes,
  minDayForLookback,
  parseHexId,
  parseHexListPayload,
  scanDedupeKey,
  scanToDetail,
  usableNodeName,
  utcDayFromTs,
} from '../src/hex_detail.ts';

const LOCK_HAVEN = { lat: 41.137, lng: -77.446 };

test('fine hex id agrees with row:col grid', () => {
  const cell = fineHexAt(LOCK_HAVEN.lat, LOCK_HAVEN.lng);
  assert.equal(cell.id, hexIdFor(cell.row, cell.col));
  assert.deepEqual(parseHexId(cell.id), { row: cell.row, col: cell.col });
  assert.deepEqual(parseHexId(`hex:${cell.id}`), { row: cell.row, col: cell.col });
  assert.deepEqual(parseHexId(`tile:${cell.id}`), { row: cell.row, col: cell.col });
  const same = fineHexAt(cell.centerLat, cell.centerLng);
  assert.equal(same.id, cell.id);
});

test('nearby points in the same hex share an id; a far point does not', () => {
  const a = fineHexAt(LOCK_HAVEN.lat, LOCK_HAVEN.lng);
  const b = fineHexAt(LOCK_HAVEN.lat + 0.0001, LOCK_HAVEN.lng + 0.0001);
  assert.equal(a.id, b.id);
  const c = fineHexAt(LOCK_HAVEN.lat + 1, LOCK_HAVEN.lng + 1);
  assert.notEqual(a.id, c.id);
});

test('day lookback: 7/30/90/All', () => {
  const now = Date.parse('2026-11-09T17:00:00Z');
  assert.equal(minDayForLookback(0, now), null);
  assert.equal(minDayForLookback(7, now), '2026-11-02');
  assert.equal(minDayForLookback(30, now), '2026-10-10');
  assert.equal(minDayForLookback(90, now), '2026-08-11');
  assert.equal(utcDayFromTs(now), '2026-11-09');
});

function sampleScan(over = {}) {
  return {
    radioId: 'ABCD1234',
    timestamp: Date.parse('2026-11-09T12:00:00Z'),
    latitude: LOCK_HAVEN.lat,
    longitude: LOCK_HAVEN.lng,
    altitude: 180,
    nodes: [
      { nodeId: 'N1', name: 'Millheim 1W', rssi: -63, snr: 12 },
      { nodeId: 'N2', name: 'Repeater', rssi: -90, snr: 4 },
    ],
    ...over,
  };
}

test('scanToDetail captures Alpha-24 per-hex fields', () => {
  const d = scanToDetail(sampleScan());
  assert.ok(d);
  assert.equal(d.scan_count, 1);
  assert.equal(d.best_snr, 12);
  assert.equal(d.best_rssi, -63);
  assert.equal(d.last_altitude, 180);
  assert.equal(d.last_node_id, 'N1');
  assert.equal(d.last_node_name, 'Millheim 1W');
  assert.equal(d.nodes.length, 3);
  assert.equal(d.nodes[0].i, 'N1');
  assert.equal(d.nodes.find((n) => n.role === 'observer').i, 'ABCD1234');
});

test('store merge is incremental and idempotent on resubmit', () => {
  const store = createMemoryHexStore();
  const scan = sampleScan();
  const first = applyScanToStore(store, scan);
  assert.equal(first.applied, true);
  const again = applyScanToStore(store, scan);
  assert.equal(again.applied, false);
  assert.equal(again.reason, 'duplicate');
  const hex = [...store.hexes.values()][0];
  assert.equal(hex.scan_count, 1);
  const later = applyScanToStore(
    store,
    sampleScan({
      timestamp: scan.timestamp + 60_000,
      nodes: [{ nodeId: 'N1', name: 'Millheim 1W', rssi: -50, snr: 15 }],
    })
  );
  assert.equal(later.applied, true);
  const merged = [...store.hexes.values()][0];
  assert.equal(merged.scan_count, 2);
  assert.equal(merged.best_rssi, -50);
  assert.equal(merged.best_snr, 15);
  assert.equal(merged.last_ts, scan.timestamp + 60_000);
  const n1 = merged.nodes.find((n) => n.i === 'N1');
  assert.equal(n1.c, 2);
  assert.equal(n1.r, -50);
});

test('history day windows filter hex_detail_day without raw rows', () => {
  const store = createMemoryHexStore();
  const now = Date.parse('2026-11-09T17:00:00Z');
  applyScanToStore(store, sampleScan({ timestamp: Date.parse('2026-11-08T12:00:00Z') }));
  applyScanToStore(store, sampleScan({
    timestamp: Date.parse('2026-09-01T12:00:00Z'),
    latitude: LOCK_HAVEN.lat + 0.05,
    longitude: LOCK_HAVEN.lng,
    nodes: [{ nodeId: 'OLD', name: 'Old', rssi: -80, snr: 1 }],
  }));
  const all = aggregateStoreForDays(store, minDayForLookback(0, now));
  const d7 = aggregateStoreForDays(store, minDayForLookback(7, now));
  const d90 = aggregateStoreForDays(store, minDayForLookback(90, now));
  assert.equal(all.length, 2);
  assert.equal(d7.length, 1);
  assert.equal(d90.length, 2);
});

test('index stores every node, including observers, with no cap', () => {
  const many = Array.from({ length: 40 }, (_, i) => ({
    i: `n${i}`,
    t: 1000 + i,
    c: 1,
    role: 'repeater',
  }));
  const merged = mergeHexNodes([], many);
  assert.equal(merged.length, 40);
  assert.equal(merged[0].i, 'n39');
  const detail = scanToDetail(sampleScan({
    radioId: 'OBS12345',
    observerName: 'Truck Radio',
    nodes: [
      { nodeId: 'ABCD1234', name: 'Millheim 1W', rssi: -70, snr: 8, observerName: 'Truck Radio' },
    ],
  }));
  const roles = Object.fromEntries(detail.nodes.map((n) => [n.role, n]));
  assert.equal(roles.repeater.i, 'ABCD1234');
  assert.equal(roles.repeater.n, 'Millheim 1W');
  assert.equal(roles.repeater.sn, 'Millheim 1W');
  assert.equal(roles.repeater.rn, 'Truck Radio');
  assert.equal(roles.observer.i, 'OBS12345');
  assert.equal(roles.observer.n, 'Truck Radio');
  assert.equal(detail.last_node_name, 'Millheim 1W');
});

test('world payload is compact, size-bounded, and round-trips', () => {
  const store = createMemoryHexStore();
  for (let i = 0; i < 20; i++) {
    applyScanToStore(store, sampleScan({
      timestamp: Date.parse('2026-11-09T12:00:00Z') + i * 1000,
      latitude: LOCK_HAVEN.lat + i * 0.02,
      radioId: `R${i}`,
    }));
  }
  const rows = [...store.hexes.values()];
  const world = buildHexListPayload(rows, { days: 0, includeNodes: false });
  assert.ok(world.bytes > 0);
  const parsedWorld = parseHexListPayload(world.body);
  assert.equal(parsedWorld.length, rows.length);
  assert.equal(parsedWorld[0].nodes.length, 0);
  const center = hexCellCenter(rows[0].row, rows[0].col);
  assert.equal(parsedWorld[0].last_lat, center.lat);
  assert.equal(parsedWorld[0].last_lng, center.lng);
  const packed = buildHexListPayload(rows, { days: 0, includeNodes: true, softByteCap: Number.POSITIVE_INFINITY });
  const parsed = parseHexListPayload(packed.body);
  assert.equal(parsed.length, rows.length);
  assert.ok(parsed[0].nodes.length >= 1);
  const tight = buildHexListPayload(rows, { days: 0, includeNodes: true, softByteCap: 200 });
  assert.equal(tight.nodesOmitted, true);
  const again = parseHexListPayload(tight.body);
  assert.equal(again.length, rows.length);
  assert.equal(again[0].nodes.length, 0);
});

test('single-hex payload has full popup fields', () => {
  const d = scanToDetail(sampleScan());
  const body = JSON.parse(buildHexDetailPayload(d, 0));
  assert.equal(body.hex.scanCount, 1);
  assert.equal(body.hex.lastNodeName, 'Millheim 1W');
  assert.equal(body.hex.bestSnr, 12);
  assert.ok(Array.isArray(body.hex.nodes));
});

test('path and dedupe helpers', () => {
  assert.equal(extractHexIdFromPath('/coverage/hex/10:-20'), '10:-20');
  assert.equal(extractHexIdFromPath('/coverage/hex-world'), null);
  assert.ok(existingScanSelectSql().includes('radioId'));
  const k = scanDedupeKey(sampleScan());
  assert.equal(scanDedupeKey(sampleScan({ radioId: 'abcd1234' })), k);
});

function memoryD1() {
  const scans = [];
  const days = new Map();
  const hexes = new Map();
  const parseList = (sql, firstClause) => {
    const idx = sql.indexOf(firstClause);
    return sql
      .slice(idx + firstClause.length)
      .split(',')
      .map((s) => s.trim().split(/\s+AS\s+/i).pop().split('.').pop().trim());
  };
  const rowFromMap = (rec) => ({ ...rec });
  return {
    _scans: scans,
    _days: days,
    _hexes: hexes,
    prepare(sql) {
      const s = sql.replace(/\s+/g, ' ').trim();
      return {
        bind(...args) {
          return {
            async first() {
              if (s.startsWith('SELECT id FROM scans')) {
                const [radio, ts, lat, lng] = args;
                const hit = scans.find(
                  (r) => r.radioId === radio && r.timestamp === ts && r.latitude === lat && r.longitude === lng
                );
                return hit ? { id: hit.id } : null;
              }
              if (s.includes('FROM hex_detail_day WHERE hex_id = ? AND day = ?')) {
                const rec = days.get(`${args[0]}|${args[1]}`);
                return rec ? rowFromMap(rec) : null;
              }
              if (s.includes('FROM hex_detail WHERE hex_id = ?') && !s.includes('hex_detail_day')) {
                const rec = hexes.get(args[0]);
                return rec ? rowFromMap(rec) : null;
              }
              return null;
            },
            async all() {
              return { results: [] };
            },
            async run() {
              if (s.startsWith('INSERT INTO hex_detail_day')) {
                const rec = {
                  hex_id: args[0],
                  day: args[1],
                  row: args[2],
                  col: args[3],
                  scan_count: args[4],
                  first_ts: args[5],
                  last_ts: args[6],
                  best_snr: args[7],
                  best_rssi: args[8],
                  last_snr: args[9],
                  last_rssi: args[10],
                  last_altitude: args[11],
                  last_lat: args[12],
                  last_lng: args[13],
                  last_node_id: args[14],
                  last_node_name: args[15],
                  nodes_json: args[16],
                };
                days.set(`${rec.hex_id}|${rec.day}`, rec);
                return { meta: { changes: 1 } };
              }
              if (s.startsWith('INSERT INTO hex_detail')) {
                const rec = {
                  hex_id: args[0],
                  row: args[1],
                  col: args[2],
                  scan_count: args[3],
                  first_ts: args[4],
                  last_ts: args[5],
                  best_snr: args[6],
                  best_rssi: args[7],
                  last_snr: args[8],
                  last_rssi: args[9],
                  last_altitude: args[10],
                  last_lat: args[11],
                  last_lng: args[12],
                  last_node_id: args[13],
                  last_node_name: args[14],
                  nodes_json: args[15],
                  updated_ms: args[16],
                };
                hexes.set(rec.hex_id, rec);
                return { meta: { changes: 1 } };
              }
              return { meta: { changes: 0 } };
            },
          };
        },
      };
    },
    insertScan(scan) {
      const id = scans.length + 1;
      scans.push({
        id,
        radioId: (scan.radioId || '').trim().toUpperCase(),
        timestamp: scan.timestamp,
        latitude: scan.latitude,
        longitude: scan.longitude,
      });
      return id;
    },
  };
}

test('ingest applyScanToHexDetail is incremental and skips resubmits', async () => {
  const db = memoryD1();
  const scan = sampleScan();
  const first = await applyScanToHexDetail(db, scan);
  assert.equal(first.applied, true);
  db.insertScan(scan);
  const again = await applyScanToHexDetail(db, scan);
  assert.equal(again.applied, false);
  assert.equal(again.reason, 'duplicate');
  const hex = [...db._hexes.values()][0];
  assert.equal(hex.scan_count, 1);
  const later = sampleScan({ timestamp: scan.timestamp + 5000, nodes: [{ nodeId: 'N3', name: 'New', rssi: -70, snr: 8 }] });
  const second = await applyScanToHexDetail(db, later);
  assert.equal(second.applied, true);
  const updated = [...db._hexes.values()][0];
  assert.equal(updated.scan_count, 2);
  assert.equal(updated.last_node_id, 'N3');
  const day = [...db._days.values()][0];
  assert.equal(day.scan_count, 2);
});

test('grid row spacing is the app constant, not merged/resized', () => {
  assert.equal(ROW_SPACING, 0.0007 * 1.5);
  const a = fineHexAt(0, 0);
  const b = fineHexAt(ROW_SPACING * 20, 0);
  assert.equal(Math.abs(b.row - a.row), 20);
});

test('payload lat/lng are the cell center, not the last scan location', () => {
  const cell = fineHexAt(LOCK_HAVEN.lat, LOCK_HAVEN.lng);
  const scan = sampleScan({ latitude: cell.centerLat + 0.0003, longitude: cell.centerLng - 0.0004 });
  const detail = scanToDetail(scan);
  assert.equal(detail.row, cell.row);
  assert.equal(detail.col, cell.col);
  assert.notEqual(detail.last_lat, cell.centerLat);
  const body = JSON.parse(buildHexDetailPayload(detail, 0));
  assert.equal(body.hex.lat, cell.centerLat);
  assert.equal(body.hex.lng, cell.centerLng);
  assert.equal(body.hex.lastLat, detail.last_lat);
  const packed = buildHexListPayload([detail], { days: 0, includeNodes: false });
  const parsed = parseHexListPayload(packed.body);
  assert.equal(parsed[0].last_lat, cell.centerLat);
  assert.equal(parsed[0].last_lng, cell.centerLng);
});

test('placeholder short ids are not usable names and cannot overwrite a real name', () => {
  const id = '8B7DE94C';
  assert.equal(isPlaceholderNodeName('', id), true);
  assert.equal(isPlaceholderNodeName('unknown', id), true);
  assert.equal(isPlaceholderNodeName('Unknown (8B7DE94C)', id), true);
  assert.equal(isPlaceholderNodeName(id, id), true);
  assert.equal(isPlaceholderNodeName('8b7de94c', id), true);
  assert.equal(isPlaceholderNodeName('463D3236'), true);
  assert.equal(isPlaceholderNodeName('CPAMe.sh Millheim', id), false);
  assert.equal(isPlaceholderNodeName('TestAbe', 'A1B2C3D4'), false);
  assert.equal(usableNodeName(id, id), undefined);
  assert.equal(usableNodeName('CPAMe.sh Millheim', id), 'CPAMe.sh Millheim');

  const named = scanToDetail(sampleScan({
    nodes: [{ nodeId: id, name: 'CPAMe.sh Millheim', rssi: -67, snr: 13 }],
  }));
  const laterPlaceholder = scanToDetail(sampleScan({
    timestamp: Date.parse('2026-11-10T17:00:00Z'),
    nodes: [{ nodeId: id, name: id, rssi: -60, snr: 12 }],
  }));
  assert.equal(named.last_node_name, 'CPAMe.sh Millheim');
  assert.equal(laterPlaceholder.last_node_name, null);

  const merged = mergeDetail(named, laterPlaceholder);
  const node = merged.nodes.find((n) => n.i === id && n.role !== 'observer');
  assert.ok(node);
  assert.equal(node.n, 'CPAMe.sh Millheim');
  assert.equal(merged.last_node_id, id);
  assert.equal(merged.last_node_name, 'CPAMe.sh Millheim');
  assert.equal(merged.scan_count, 2);

  const filledFromPlaceholder = mergeDetail(laterPlaceholder, named);
  assert.equal(filledFromPlaceholder.nodes.find((n) => n.i === id && n.role !== 'observer').n, 'CPAMe.sh Millheim');
  assert.equal(filledFromPlaceholder.last_node_name, 'CPAMe.sh Millheim');

  const catalog = emptyNameCatalog();
  addNameToCatalog(catalog, id, id);
  addNameToCatalog(catalog, id, 'CPAMe.sh Millheim');
  addNameToCatalog(catalog, id, id);
  assert.equal(lookupCatalogName(catalog, id), 'CPAMe.sh Millheim');
  const filled = applyNameCatalog(laterPlaceholder, catalog);
  assert.equal(filled.nodes.find((n) => n.i === id && n.role !== 'observer').n, 'CPAMe.sh Millheim');
  assert.equal(filled.last_node_name, 'CPAMe.sh Millheim');

  const store = createMemoryHexStore();
  const firstScan = sampleScan({
    nodes: [{ nodeId: id, name: 'CPAMe.sh Millheim', rssi: -67, snr: 13 }],
  });
  const secondScan = sampleScan({
    timestamp: Date.parse('2026-11-10T17:00:00Z'),
    nodes: [{ nodeId: id, name: id, rssi: -60, snr: 12 }],
  });
  applyScanToStore(store, firstScan);
  applyScanToStore(store, secondScan);
  const hex = [...store.hexes.values()][0];
  assert.equal(hex.scan_count, 2);
  assert.equal(hex.last_node_name, 'CPAMe.sh Millheim');
  assert.equal(hex.nodes.find((n) => n.i === id && n.role !== 'observer').n, 'CPAMe.sh Millheim');
});
