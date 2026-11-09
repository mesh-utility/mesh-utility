/**
 * Geographic query for /history/:day.ndjson and /coverage.
 *
 * Resolution order (first match wins):
 * 1. minLat, maxLat, minLng, maxLng — explicit bbox. lat/lng/radiusMiles are
 *    ignored for the SQL predicate. minLng > maxLng is the antimeridian
 *    (two ranges: minLng..180 and -180..maxLng), not a swapped box.
 *    minLat > maxLat, a latitude span above 180°, or a coordinate outside
 *    [-90,90] / [-180,180] is 400. A box that covers the whole globe
 *    (lat span ≥ 179° and lng span ≥ 359°) is worldwide when no positive
 *    radiusMiles is present. The same box combined with a positive
 *    radiusMiles is 400: the radius would be ignored, so the mix is rejected.
 * 2. Repeatable `division` ids, resolved through division_bboxes.ts
 *    (id → bbox, not a polygon). More than 32 ids is 400. Unknown ids are
 *    ignored. If every id is unknown, the page is empty — not worldwide.
 *    Each known box is its own range (antimeridian boxes become two). The
 *    SQL union is those ranges, not one bounding box around all of them.
 * 3. lat + lng + radiusMiles via buildGeoBounds. parseRadiusMiles still
 *    clamps to 250. This path is unchanged for old clients.
 * 4. Otherwise worldwide (no geo predicate), same as a missing radius today.
 *
 * `polygon` is a single ring of lng,lat pairs, at most 64 points. It is
 * applied in JS to rows the bbox query already returned. It is never a D1
 * predicate. The history cursor stays the underlying scan (timestamp, id).
 *
 * Bbox and division edges are rounded outward to 0.1° before SQL so the
 * cache key and the query match. Radius queries keep the exact box and the
 * exact URL key.
 *
 * D1 allows 100 bound parameters per statement. A multi-range read is
 * chunked UNION ALL of per-range SELECTs. History puts LIMIT pageSize+1 on
 * each range (the global top K is contained in the union of each range's
 * top K). The worker merges, dedupes by id, and keeps one page.
 */

import { divisionBboxes as shippedDivisionBboxes } from './division_bboxes';

export const HISTORY_PAGE_SIZE_MAX = 1000;
export const HISTORY_PAGE_SIZE_DEFAULT = 1000;
/** About 1 MB of NDJSON per history page. Stop early and set X-Has-More. */
export const HISTORY_PAGE_BYTE_BUDGET = 1_000_000;
/** Bbox and division coverage responses keep at most this many hex zones. */
export const COVERAGE_ZONE_CAP = 5000;
export const DIVISION_ID_CAP = 32;
export const POLYGON_POINT_CAP = 64;
export const BBOX_ROUND_DEGREES = 0.1;
export const D1_MAX_BOUND_PARAMETERS = 100;

export type GeoBounds = {
  minLat: number;
  maxLat: number;
  minLng: number;
  maxLng: number;
};

export type GeoQueryKind = 'bbox' | 'division' | 'radius' | 'worldwide';

/** [minLat, maxLat, minLng, maxLng]. minLng > maxLng crosses the antimeridian. */
export type DivisionBboxTuple = readonly [number, number, number, number];
export type DivisionBboxTable = Readonly<Record<string, DivisionBboxTuple>>;

export type ResolvedGeo = {
  /**
   * The single SQL box when there is exactly one range.
   * Null for worldwide, empty, error, antimeridian, and multi-division unions.
   */
  bounds: GeoBounds | null;
  /** SQL ranges. Null means no geo predicate. */
  ranges: GeoBounds[] | null;
  error?: Response;
  /** Every division id was unknown. Callers return an empty 200, not worldwide. */
  empty?: boolean;
  kind: GeoQueryKind;
};

export type BoundQuery = {
  sql: string;
  binds: number[];
};

export type HistoryChunk = { bytes: number } | null;

export type HistoryPagePlan = {
  emit: boolean[];
  hasMore: boolean;
  /** Index into the SQL page. -1 when the response has no cursor. */
  cursorIndex: number;
};

const HISTORY_COLUMNS = 'id, radioId, timestamp, latitude, longitude, altitude, nodes';
const COVERAGE_COLUMNS = 'radioId, timestamp, latitude, longitude, nodes';
const COVERAGE_COLUMNS_WITH_ID = 'id, radioId, timestamp, latitude, longitude, nodes';

export function parseFiniteFloat(raw: string | null): number | null {
  if (raw == null) return null;
  const parsed = Number.parseFloat(raw);
  return Number.isFinite(parsed) ? parsed : null;
}

/** Positive miles, hard-capped at 250. Zero, negative, and junk are null. */
export function parseRadiusMiles(raw: string | null): number | null {
  const parsed = parseFiniteFloat(raw);
  if (parsed == null || parsed <= 0) return null;
  return Math.min(parsed, 250);
}

export function buildGeoBounds(
  latRaw: string | null,
  lngRaw: string | null,
  radiusMilesRaw: string | null
): GeoBounds | null {
  const lat = parseFiniteFloat(latRaw);
  const lng = parseFiniteFloat(lngRaw);
  const radiusMiles = parseRadiusMiles(radiusMilesRaw);
  if (lat == null || lng == null || radiusMiles == null) return null;

  const latDelta = radiusMiles / 69;
  const cosLat = Math.cos((lat * Math.PI) / 180);
  const safeCosLat = Math.max(Math.abs(cosLat), 0.1);
  const lngDelta = radiusMiles / (69 * safeCosLat);
  return {
    minLat: lat - latDelta,
    maxLat: lat + latDelta,
    minLng: lng - lngDelta,
    maxLng: lng + lngDelta,
  };
}

function errorGeo(status: number, message: string, kind: GeoQueryKind): ResolvedGeo {
  return {
    bounds: null,
    ranges: null,
    kind,
    error: new Response(JSON.stringify({ error: message }), {
      status,
      headers: { 'Content-Type': 'application/json' },
    }),
  };
}

function single(kind: GeoQueryKind, bounds: GeoBounds): ResolvedGeo {
  return { bounds, ranges: [bounds], kind };
}

function multi(kind: GeoQueryKind, ranges: GeoBounds[]): ResolvedGeo {
  if (ranges.length === 1) return single(kind, ranges[0]);
  return { bounds: null, ranges, kind };
}

function worldwide(): ResolvedGeo {
  return { bounds: null, ranges: null, kind: 'worldwide' };
}

function longitudeSpan(minLng: number, maxLng: number): number {
  if (minLng <= maxLng) return maxLng - minLng;
  return 180 - minLng + (maxLng + 180);
}

function isWholeGlobe(minLat: number, maxLat: number, minLng: number, maxLng: number): boolean {
  return maxLat - minLat >= 179 && longitudeSpan(minLng, maxLng) >= 359;
}

function expandTuple(tuple: DivisionBboxTuple): GeoBounds[] {
  const [minLat, maxLat, minLng, maxLng] = tuple;
  if (minLng > maxLng) {
    return [
      { minLat, maxLat, minLng, maxLng: 180 },
      { minLat, maxLat, minLng: -180, maxLng },
    ];
  }
  return [{ minLat, maxLat, minLng, maxLng }];
}

function hasPositiveRadius(url: URL): boolean {
  const parsed = parseFiniteFloat(url.searchParams.get('radiusMiles'));
  return parsed != null && parsed > 0;
}

function resolveBbox(url: URL): ResolvedGeo | null {
  const keys = ['minLat', 'maxLat', 'minLng', 'maxLng'] as const;
  const present = keys.filter((key) => url.searchParams.has(key));
  if (present.length === 0) return null;
  if (present.length !== keys.length) {
    return errorGeo(400, 'minLat, maxLat, minLng, and maxLng must be sent together', 'bbox');
  }
  const minLat = parseFiniteFloat(url.searchParams.get('minLat'));
  const maxLat = parseFiniteFloat(url.searchParams.get('maxLat'));
  const minLng = parseFiniteFloat(url.searchParams.get('minLng'));
  const maxLng = parseFiniteFloat(url.searchParams.get('maxLng'));
  if (minLat == null || maxLat == null || minLng == null || maxLng == null) {
    return errorGeo(400, 'bbox parameters must all be finite numbers', 'bbox');
  }
  // Swapped latitude is a client error. Swapped longitude is the antimeridian.
  if (minLat > maxLat) {
    return errorGeo(400, 'minLat is greater than maxLat', 'bbox');
  }
  if (maxLat - minLat > 180) {
    return errorGeo(400, 'latitude span exceeds 180 degrees', 'bbox');
  }
  if (minLat < -90 || maxLat > 90 || minLng < -180 || maxLng > 180) {
    return errorGeo(400, 'latitude or longitude is out of range', 'bbox');
  }
  if (isWholeGlobe(minLat, maxLat, minLng, maxLng)) {
    if (hasPositiveRadius(url)) {
      return errorGeo(
        400,
        'a worldwide bbox cannot be combined with radiusMiles',
        'bbox'
      );
    }
    // A deliberate full-world box with no radius is the same as omitting geo.
    return worldwide();
  }
  if (minLng > maxLng) {
    return multi('bbox', [
      { minLat, maxLat, minLng, maxLng: 180 },
      { minLat, maxLat, minLng: -180, maxLng },
    ]);
  }
  return single('bbox', { minLat, maxLat, minLng, maxLng });
}

function resolveDivisions(url: URL, table: DivisionBboxTable): ResolvedGeo | null {
  const ids = url.searchParams
    .getAll('division')
    .map((id) => id.trim())
    .filter((id) => id.length > 0);
  if (ids.length === 0) return null;
  if (ids.length > DIVISION_ID_CAP) {
    return errorGeo(400, `at most ${DIVISION_ID_CAP} division parameters`, 'division');
  }
  const ranges: GeoBounds[] = [];
  for (const id of ids) {
    const tuple = table[id];
    if (!tuple) continue;
    ranges.push(...expandTuple(tuple));
  }
  if (ranges.length === 0) {
    return { bounds: null, ranges: null, kind: 'division', empty: true };
  }
  return multi('division', ranges);
}

export function resolveGeoBounds(
  url: URL,
  divisions: DivisionBboxTable = shippedDivisionBboxes
): ResolvedGeo {
  const bbox = resolveBbox(url);
  if (bbox) return bbox;
  const division = resolveDivisions(url, divisions);
  if (division) return division;
  const radius = buildGeoBounds(
    url.searchParams.get('lat'),
    url.searchParams.get('lng'),
    url.searchParams.get('radiusMiles')
  );
  if (radius) return single('radius', radius);
  return worldwide();
}

export type PolygonParse = {
  ring: Array<[number, number]> | null;
  error?: Response;
};

/** `polygon` is comma-separated lng,lat pairs. Absent means no filter. */
export function parsePolygon(raw: string | null): PolygonParse {
  if (raw == null || raw.trim() === '') return { ring: null };
  const parts = raw.split(/[\s,]+/).filter((part) => part.length > 0);
  if (parts.length % 2 !== 0) {
    return {
      ring: null,
      error: new Response(JSON.stringify({ error: 'polygon must be lng,lat pairs' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      }),
    };
  }
  const count = parts.length / 2;
  if (count > POLYGON_POINT_CAP) {
    return {
      ring: null,
      error: new Response(
        JSON.stringify({ error: `polygon has more than ${POLYGON_POINT_CAP} points` }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      ),
    };
  }
  if (count < 3) {
    return {
      ring: null,
      error: new Response(JSON.stringify({ error: 'polygon must have at least 3 points' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      }),
    };
  }
  const ring: Array<[number, number]> = [];
  for (let i = 0; i < parts.length; i += 2) {
    const lng = Number(parts[i]);
    const lat = Number(parts[i + 1]);
    if (!Number.isFinite(lng) || !Number.isFinite(lat)) {
      return {
        ring: null,
        error: new Response(JSON.stringify({ error: 'polygon coordinates must be finite' }), {
          status: 400,
          headers: { 'Content-Type': 'application/json' },
        }),
      };
    }
    ring.push([lng, lat]);
  }
  return { ring };
}

/** Ray cast. Boundary points count as inside. */
export function pointInRing(
  lng: number,
  lat: number,
  ring: ReadonlyArray<readonly [number, number]>
): boolean {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i];
    const [xj, yj] = ring[j];
    if (pointOnSegment(lng, lat, xi, yi, xj, yj)) return true;
    const crosses = yi > lat !== yj > lat;
    if (!crosses) continue;
    const x = ((xj - xi) * (lat - yi)) / (yj - yi) + xi;
    if (lng < x) inside = !inside;
  }
  return inside;
}

function pointOnSegment(
  lng: number,
  lat: number,
  x1: number,
  y1: number,
  x2: number,
  y2: number
): boolean {
  const cross = (lat - y1) * (x2 - x1) - (lng - x1) * (y2 - y1);
  if (Math.abs(cross) > 1e-9) return false;
  const dot = (lng - x1) * (x2 - x1) + (lat - y1) * (y2 - y1);
  if (dot < 0) return false;
  const lenSq = (x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1);
  return dot <= lenSq + 1e-9;
}

function tenthFloor(value: number): number {
  const scaled = value * 10;
  const nearest = Math.round(scaled);
  if (Math.abs(scaled - nearest) < 1e-6) return nearest / 10;
  return Math.floor(scaled) / 10;
}

function tenthCeil(value: number): number {
  const scaled = value * 10;
  const nearest = Math.round(scaled);
  if (Math.abs(scaled - nearest) < 1e-6) return nearest / 10;
  return Math.ceil(scaled) / 10;
}

function snapTenth(value: number): number {
  const snapped = Math.round(value * 10) / 10;
  return Object.is(snapped, -0) ? 0 : snapped;
}

/** Expand a box onto the 0.1° grid. Edges already on the grid stay put. */
export function roundOutward(bounds: GeoBounds, step = BBOX_ROUND_DEGREES): GeoBounds {
  if (step !== 0.1) {
    const floor = (value: number) => Math.floor(value / step + 1e-9) * step;
    const ceil = (value: number) => Math.ceil(value / step - 1e-9) * step;
    return clampBounds({
      minLat: floor(bounds.minLat),
      maxLat: ceil(bounds.maxLat),
      minLng: floor(bounds.minLng),
      maxLng: ceil(bounds.maxLng),
    });
  }
  return clampBounds({
    minLat: snapTenth(tenthFloor(bounds.minLat)),
    maxLat: snapTenth(tenthCeil(bounds.maxLat)),
    minLng: snapTenth(tenthFloor(bounds.minLng)),
    maxLng: snapTenth(tenthCeil(bounds.maxLng)),
  });
}

function clampBounds(bounds: GeoBounds): GeoBounds {
  let minLat = Math.max(-90, Math.min(90, bounds.minLat));
  let maxLat = Math.max(-90, Math.min(90, bounds.maxLat));
  let minLng = Math.max(-180, Math.min(180, bounds.minLng));
  let maxLng = Math.max(-180, Math.min(180, bounds.maxLng));
  if (minLat > maxLat) {
    minLat = maxLat;
  }
  return { minLat, maxLat, minLng, maxLng };
}

export function formatGridDegrees(value: number): string {
  const snapped = snapTenth(value);
  return snapped.toFixed(1);
}

/** Rebuild a 4-parameter bbox from one range or an antimeridian pair. */
export function bboxParamsFromRoundedRanges(ranges: GeoBounds[]): GeoBounds | null {
  if (ranges.length === 1) return ranges[0];
  if (ranges.length !== 2) return null;
  const [a, b] = ranges;
  const aEast = a.maxLng === 180 || a.minLng > 0;
  const east = aEast ? a : b;
  const west = aEast ? b : a;
  if (east.minLng > west.maxLng) {
    return {
      minLat: Math.min(a.minLat, b.minLat),
      maxLat: Math.max(a.maxLat, b.maxLat),
      minLng: east.minLng,
      maxLng: west.maxLng,
    };
  }
  return null;
}

/**
 * Cache key for an area query.
 * Bbox keys replace the four edges with the outward-rounded grid.
 * Division keys keep the division id list (already discrete). `_debug` is dropped.
 * Radius and worldwide return null so callers keep today's exact URL key.
 */
export function buildAreaCacheUrl(
  url: URL,
  geo: ResolvedGeo,
  roundedRanges: GeoBounds[]
): URL | null {
  if (geo.kind !== 'bbox' && geo.kind !== 'division') return null;
  const next = new URL(url.toString());
  next.searchParams.delete('_debug');
  if (geo.kind === 'bbox') {
    const params = bboxParamsFromRoundedRanges(roundedRanges);
    if (params) {
      next.searchParams.set('minLat', formatGridDegrees(params.minLat));
      next.searchParams.set('maxLat', formatGridDegrees(params.maxLat));
      next.searchParams.set('minLng', formatGridDegrees(params.minLng));
      next.searchParams.set('maxLng', formatGridDegrees(params.maxLng));
    }
  }
  return next;
}

export function prepareAreaQuery(
  url: URL,
  geo: ResolvedGeo,
  allowCache = true
): { ranges: GeoBounds[] | null; cacheUrl: URL | null } {
  if (geo.error) return { ranges: null, cacheUrl: null };
  if (geo.kind !== 'bbox' && geo.kind !== 'division') {
    return { ranges: geo.ranges, cacheUrl: null };
  }
  // Empty division: no SQL ranges. The cache key is still the division URL.
  const ranges = geo.empty ? null : (geo.ranges ?? []).map((bounds) => roundOutward(bounds));
  if (!allowCache) return { ranges, cacheUrl: null };
  return { ranges, cacheUrl: buildAreaCacheUrl(url, geo, ranges ?? []) };
}

export function dedupeCoverageRows<T extends ScanIdentity>(rows: T[]): T[] {
  const copy = rows.slice();
  copy.sort((a, b) => {
    if (a.timestamp !== b.timestamp) return a.timestamp - b.timestamp;
    return (a.id ?? 0) - (b.id ?? 0);
  });
  const seen = new Set<number>();
  const out: T[] = [];
  for (const row of copy) {
    if (row.id != null) {
      if (seen.has(row.id)) continue;
      seen.add(row.id);
    }
    out.push(row);
  }
  return out;
}

function assertBinds(binds: number[]): void {
  if (binds.length > D1_MAX_BOUND_PARAMETERS) {
    throw new Error(`D1 bind limit exceeded (${binds.length} > ${D1_MAX_BOUND_PARAMETERS})`);
  }
}

function historyBranchSql(hasCursor: boolean): string {
  const cursor = hasCursor ? 'AND (timestamp > ? OR (timestamp = ? AND id > ?))' : '';
  return `SELECT ${HISTORY_COLUMNS}
FROM scans
WHERE timestamp >= ? AND timestamp <= ?
  AND latitude BETWEEN ? AND ?
  AND longitude BETWEEN ? AND ?
  ${cursor}
ORDER BY timestamp ASC, id ASC
LIMIT ?`;
}

function historyNoGeoSql(hasCursor: boolean): string {
  const cursor = hasCursor ? 'AND (timestamp > ? OR (timestamp = ? AND id > ?))' : '';
  return `SELECT ${HISTORY_COLUMNS}
FROM scans
WHERE timestamp >= ? AND timestamp <= ?
  ${cursor}
ORDER BY timestamp ASC, id ASC
LIMIT ?`;
}

function chunkItems<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  const step = Math.max(1, size);
  for (let i = 0; i < items.length; i += step) out.push(items.slice(i, i + step));
  return out;
}

/**
 * One statement when there is a single range or no geo filter.
 * Several ranges become chunked UNION ALL statements, each under 100 binds.
 * Every branch fetches pageSize+1 rows ordered by (timestamp, id). The caller
 * merges those lists. That is the global top pageSize+1.
 */
export function buildHistoryQueries(args: {
  ranges: GeoBounds[] | null;
  dayStart: number;
  dayEnd: number;
  pageSize: number;
  cursorTimestamp?: number;
  cursorId?: number;
}): BoundQuery[] {
  const limit = args.pageSize + 1;
  const hasCursor = args.cursorTimestamp != null && args.cursorId != null;
  const cursorTs = args.cursorTimestamp ?? 0;
  const cursorId = args.cursorId ?? 0;
  if (args.ranges == null) {
    const binds = hasCursor
      ? [args.dayStart, args.dayEnd, cursorTs, cursorTs, cursorId, limit]
      : [args.dayStart, args.dayEnd, limit];
    assertBinds(binds);
    return [{ sql: historyNoGeoSql(hasCursor), binds }];
  }
  if (args.ranges.length === 1) {
    const range = args.ranges[0];
    const binds = [
      args.dayStart,
      args.dayEnd,
      range.minLat,
      range.maxLat,
      range.minLng,
      range.maxLng,
    ];
    if (hasCursor) binds.push(cursorTs, cursorTs, cursorId);
    binds.push(limit);
    assertBinds(binds);
    return [{ sql: historyBranchSql(hasCursor), binds }];
  }
  const perBranch = hasCursor ? 10 : 7;
  const perStatement = Math.floor(D1_MAX_BOUND_PARAMETERS / perBranch);
  const queries: BoundQuery[] = [];
  for (const group of chunkItems(args.ranges, perStatement)) {
    const parts: string[] = [];
    const binds: number[] = [];
    for (const range of group) {
      parts.push(`SELECT * FROM (${historyBranchSql(hasCursor)})`);
      binds.push(args.dayStart, args.dayEnd, range.minLat, range.maxLat, range.minLng, range.maxLng);
      if (hasCursor) binds.push(cursorTs, cursorTs, cursorId);
      binds.push(limit);
    }
    const sql = `SELECT ${HISTORY_COLUMNS} FROM (\n${parts.join('\nUNION ALL\n')}\n)`;
    assertBinds(binds);
    queries.push({ sql, binds });
  }
  return queries;
}

function coverageBranchSql(): string {
  return `SELECT ${COVERAGE_COLUMNS_WITH_ID}
FROM scans
WHERE timestamp >= ? AND timestamp <= ?
  AND latitude BETWEEN ? AND ?
  AND longitude BETWEEN ? AND ?`;
}

export function buildCoverageQueries(args: {
  ranges: GeoBounds[] | null;
  minTs: number;
  maxTs: number;
}): BoundQuery[] {
  if (args.ranges == null) {
    const binds = [args.minTs, args.maxTs];
    assertBinds(binds);
    return [{
      sql: `SELECT ${COVERAGE_COLUMNS}
FROM scans
WHERE timestamp >= ? AND timestamp <= ?
ORDER BY timestamp ASC`,
      binds,
    }];
  }
  if (args.ranges.length === 1) {
    const range = args.ranges[0];
    const binds = [args.minTs, args.maxTs, range.minLat, range.maxLat, range.minLng, range.maxLng];
    assertBinds(binds);
    return [{
      sql: `SELECT ${COVERAGE_COLUMNS}
FROM scans
WHERE timestamp >= ? AND timestamp <= ?
  AND latitude BETWEEN ? AND ?
  AND longitude BETWEEN ? AND ?
ORDER BY timestamp ASC`,
      binds,
    }];
  }
  const perBranch = 6;
  const perStatement = Math.floor(D1_MAX_BOUND_PARAMETERS / perBranch);
  const queries: BoundQuery[] = [];
  for (const group of chunkItems(args.ranges, perStatement)) {
    const parts: string[] = [];
    const binds: number[] = [];
    for (const range of group) {
      parts.push(coverageBranchSql());
      binds.push(args.minTs, args.maxTs, range.minLat, range.maxLat, range.minLng, range.maxLng);
    }
    const sql = `SELECT ${COVERAGE_COLUMNS_WITH_ID} FROM (\n${parts.join('\nUNION ALL\n')}\n) ORDER BY timestamp ASC, id ASC`;
    assertBinds(binds);
    queries.push({ sql, binds });
  }
  return queries;
}

export type ScanIdentity = { id?: number | null; timestamp: number };

/** Merge per-range pages. Duplicates (overlapping boxes) collapse by id. */
export function mergeHistoryRows<T extends ScanIdentity>(
  groups: T[][],
  pageSize: number
): { rows: T[]; hasMore: boolean } {
  const all: T[] = [];
  for (const group of groups) all.push(...group);
  all.sort((a, b) => {
    if (a.timestamp !== b.timestamp) return a.timestamp - b.timestamp;
    return (a.id ?? 0) - (b.id ?? 0);
  });
  const seen = new Set<number>();
  const unique: T[] = [];
  for (const row of all) {
    if (row.id != null) {
      if (seen.has(row.id)) continue;
      seen.add(row.id);
    }
    if (unique.length === pageSize) {
      return { rows: unique, hasMore: true };
    }
    unique.push(row);
  }
  return { rows: unique, hasMore: false };
}

/**
 * Byte budget is per scan, not per NDJSON line, so a scan's nodes stay together.
 * `chunks[i]` is null when the row is dropped (polygon or deadzone filter).
 * A dropped row still counts as consumed when the page is not cut short for
 * size: the cursor is then the last SQL row, and X-Has-More follows the SQL
 * page. A short page from the byte budget points the cursor at the last
 * emitted scan and sets has-more.
 */
export function planHistoryPage(
  chunks: HistoryChunk[],
  sqlHasMore: boolean,
  budget = HISTORY_PAGE_BYTE_BUDGET
): HistoryPagePlan {
  const emit = chunks.map(() => false);
  let bytes = 0;
  let emitted = 0;
  let lastEmitted = -1;
  for (let i = 0; i < chunks.length; i++) {
    const chunk = chunks[i];
    if (chunk == null) continue;
    const addition = chunk.bytes + (emitted > 0 ? 1 : 0);
    if (emitted > 0 && bytes + addition > budget) {
      return { emit, hasMore: true, cursorIndex: lastEmitted };
    }
    emit[i] = true;
    bytes += addition;
    emitted += 1;
    lastEmitted = i;
  }
  const cursorIndex = sqlHasMore && chunks.length > 0 ? chunks.length - 1 : -1;
  return { emit, hasMore: sqlHasMore, cursorIndex };
}

/**
 * Bbox and division coverage stop accepting new hexes at the cap.
 * Radius and worldwide coverage are not capped.
 */
export function coverageZoneAccepted(
  existingZones: number,
  isNew: boolean,
  capZones: boolean,
  cap = COVERAGE_ZONE_CAP
): { accept: boolean; truncated: boolean } {
  if (!capZones || !isNew) return { accept: true, truncated: false };
  if (existingZones >= cap) return { accept: false, truncated: true };
  return { accept: true, truncated: false };
}
