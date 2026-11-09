/**
 * Worldwide general-coverage layer for GET /coverage/overview.
 *
 * Cells are the app's zoomed-out hexes (scale 256, the same odd-row grid as
 * lib/src/services/grid.dart and mapHexMaxScale). The JSON has a cell id,
 * a strength bucket, a recency bucket, and a coarse count bucket. It does
 * not include radio ids, node names, scan coordinates, or sub-day times.
 *
 * Read limits match the other map reads: a fixed 90-day lookback (the same
 * window as COVERAGE_MAX_DAYS), a hard cell cap, and the edge cache. Query
 * parameters are ignored so a caller cannot widen the window or shard the cache.
 */

export const OVERVIEW_HEX_SCALE = 256;
/** Same ceiling as COVERAGE_MAX_DAYS on /coverage. Do not raise one alone. */
export const OVERVIEW_LOOKBACK_DAYS = 90;
export const OVERVIEW_CELL_CAP = 20_000;
export const OVERVIEW_FRESH_MS = 3_600_000;
export const OVERVIEW_STALE_MS = 86_400_000;
export const OVERVIEW_CACHE_CONTROL =
  'public, max-age=3600, stale-while-revalidate=86400';
/** Kept in caches.default for the fresh window plus stale-while-revalidate. */
export const OVERVIEW_STORE_CACHE_CONTROL = 'public, max-age=90000';
export const OVERVIEW_PATH = '/coverage/overview';

const HEX_SIZE = 0.0007;
const LNG_SCALE = 1.2;
/** Dart's `1.7320508075688772`, identical to Math.sqrt(3). */
const SQRT3 = 1.7320508075688772;
const ROW_SPACING = HEX_SIZE * 1.5;
const COL_SPACING = HEX_SIZE * SQRT3 * LNG_SCALE;
const DAY_MS = 86_400_000;
const NODE_SLOTS = 8;

export type OverviewAggRow = {
  row_key: number | string;
  col_key: number | string;
  max_ts: number | string | null;
  n: number | string | null;
  heard: number | string | null;
  best_rssi: number | string | null;
  best_snr: number | string | null;
};

export type OverviewCellJson = {
  id: string;
  s: number;
  r: number;
  n: number;
};

export type OverviewCacheEntry = {
  body: string;
  storedAtMs: number;
};

export interface OverviewCache {
  match(key: string): Promise<OverviewCacheEntry | null>;
  put(key: string, entry: OverviewCacheEntry): Promise<void>;
}

export type OverviewLoader = (nowMs: number) => Promise<OverviewAggRow[]>;

export type OverviewCacheAction = 'miss' | 'fresh' | 'stale';

/** Half away from zero. Matches Dart `round` and SQLite `ROUND`. */
export function roundHalfAwayFromZero(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.sign(value) * Math.round(Math.abs(value));
}

export function overviewGrid(scale = OVERVIEW_HEX_SCALE): {
  rowSpace: number;
  colSpace: number;
  halfCol: number;
} {
  const safe = scale < 1 ? 1 : scale;
  const rowSpace = ROW_SPACING * safe;
  const colSpace = COL_SPACING * safe;
  return { rowSpace, colSpace, halfCol: colSpace / 2 };
}

/** Parent cell at [scale]. The id is `row:col` on this grid. */
export function overviewCellAt(
  lat: number,
  lng: number,
  scale = OVERVIEW_HEX_SCALE
): { row: number; col: number; centerLat: number; centerLng: number } {
  const { rowSpace, colSpace } = overviewGrid(scale);
  const row = roundHalfAwayFromZero(lat / rowSpace);
  const odd = Math.abs(row) % 2 === 1;
  const offset = odd ? colSpace / 2 : 0;
  const col = roundHalfAwayFromZero((lng - offset) / colSpace);
  return {
    row,
    col,
    centerLat: row * rowSpace,
    centerLng: col * colSpace + offset,
  };
}

export function overviewCellId(row: number, col: number): string {
  return `${row}:${col}`;
}

/**
 * 0 none, 1 poor, 2 marginal, 3 fair, 4 good or excellent.
 * Thresholds match lib/src/services/signal_class.dart, with level 5 folded
 * into bucket 4 so the payload stays 0–4.
 */
export function strengthBucketFromSignal(
  rssi: number | null,
  snr: number | null
): number | null {
  const rssiOk = rssi != null && Number.isFinite(rssi);
  const snrOk = snr != null && Number.isFinite(snr);
  if (!rssiOk && !snrOk) return null;

  const rssiLevel = (): number => {
    if (!rssiOk || rssi == null) return 3;
    if (rssi > -90) return 5;
    if (rssi > -100) return 4;
    if (rssi > -110) return 3;
    if (rssi > -115) return 2;
    return 1;
  };
  const snrLevel = (): number => {
    if (!snrOk || snr == null) return 3;
    if (snr > 10) return 5;
    if (snr > 0) return 4;
    if (snr > -7) return 3;
    if (snr > -13) return 2;
    return 1;
  };
  const level = Math.min(rssiLevel(), snrLevel());
  if (level >= 5) return 4;
  if (level <= 0) return 0;
  return level;
}

/** Heard scans / scans in the cell, when no RSSI or SNR was available. */
export function strengthBucketFromRatio(heard: number, total: number): number {
  if (total <= 0 || heard <= 0) return 0;
  const ratio = heard / total;
  if (ratio < 0.25) return 1;
  if (ratio < 0.5) return 2;
  if (ratio < 0.75) return 3;
  return 4;
}

/** 0: <=7 calendar days, 1: <=30, 2: older. Day resolution only. */
export function recencyBucket(maxTs: number, nowMs: number): number {
  if (!Number.isFinite(maxTs) || maxTs <= 0 || !Number.isFinite(nowMs)) return 2;
  const ageDays = Math.floor(nowMs / DAY_MS) - Math.floor(maxTs / DAY_MS);
  if (ageDays <= 7) return 0;
  if (ageDays <= 30) return 1;
  return 2;
}

/** 0: 1 scan, 1: 2–9, 2: 10–99, 3: 100–999, 4: 1000+. */
export function countBucket(scanCount: number): number {
  if (scanCount <= 1) return 0;
  if (scanCount < 10) return 1;
  if (scanCount < 100) return 2;
  if (scanCount < 1000) return 3;
  return 4;
}

function finite(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string' && value.trim() !== '') {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}

export function cellsFromAggRows(
  rows: OverviewAggRow[],
  nowMs: number,
  cap = OVERVIEW_CELL_CAP
): { cells: OverviewCellJson[]; truncated: boolean } {
  const limited = rows.length > cap ? rows.slice(0, cap) : rows;
  const cells: OverviewCellJson[] = [];
  for (const row of limited) {
    const rowKey = finite(row.row_key);
    const colKey = finite(row.col_key);
    if (rowKey == null || colKey == null) continue;
    const rowInt = roundHalfAwayFromZero(rowKey);
    const colInt = roundHalfAwayFromZero(colKey);
    const total = finite(row.n) ?? 0;
    const heard = finite(row.heard) ?? 0;
    const rssi = finite(row.best_rssi);
    const snr = finite(row.best_snr);
    const fromSignal = strengthBucketFromSignal(rssi, snr);
    const strength = fromSignal == null ? strengthBucketFromRatio(heard, total) : fromSignal;
    const maxTs = finite(row.max_ts) ?? 0;
    cells.push({
      id: overviewCellId(rowInt, colInt),
      s: strength,
      r: recencyBucket(maxTs, nowMs),
      n: countBucket(total),
    });
  }
  return { cells, truncated: rows.length > cap };
}

export function buildOverviewPayload(
  rows: OverviewAggRow[],
  nowMs: number,
  cap = OVERVIEW_CELL_CAP
): { body: string; truncated: boolean; cellCount: number } {
  const built = cellsFromAggRows(rows, nowMs, cap);
  const payload: Record<string, unknown> = {
    generatedDay: new Date(nowMs).toISOString().slice(0, 10),
    scale: OVERVIEW_HEX_SCALE,
    cells: built.cells,
  };
  if (built.truncated) payload.truncated = true;
  const body = JSON.stringify(payload);
  return { body, truncated: built.truncated, cellCount: built.cells.length };
}

export type OverviewSample = {
  latitude: number;
  longitude: number;
  timestamp: number;
  rssi?: number | null;
  snr?: number | null;
};

/** In-memory stand-in for the SQL GROUP BY, used by tests and as the spec. */
export function aggregateOverviewSamples(
  samples: OverviewSample[],
  nowMs: number,
  cap = OVERVIEW_CELL_CAP
): OverviewCellJson[] {
  const grouped = new Map<
    string,
    {
      row: number;
      col: number;
      maxTs: number;
      n: number;
      heard: number;
      bestRssi: number | null;
      bestSnr: number | null;
    }
  >();
  for (const sample of samples) {
    const cell = overviewCellAt(sample.latitude, sample.longitude);
    const id = overviewCellId(cell.row, cell.col);
    let agg = grouped.get(id);
    if (!agg) {
      agg = {
        row: cell.row,
        col: cell.col,
        maxTs: sample.timestamp,
        n: 0,
        heard: 0,
        bestRssi: null,
        bestSnr: null,
      };
      grouped.set(id, agg);
    }
    agg.n += 1;
    if (sample.timestamp > agg.maxTs) agg.maxTs = sample.timestamp;
    const rssi = sample.rssi;
    const snr = sample.snr;
    const heard = (rssi != null && Number.isFinite(rssi)) || (snr != null && Number.isFinite(snr));
    if (heard) agg.heard += 1;
    if (rssi != null && Number.isFinite(rssi) && (agg.bestRssi == null || rssi > agg.bestRssi)) {
      agg.bestRssi = rssi;
    }
    if (snr != null && Number.isFinite(snr) && (agg.bestSnr == null || snr > agg.bestSnr)) {
      agg.bestSnr = snr;
    }
  }
  const rows: OverviewAggRow[] = [...grouped.values()]
    .sort((a, b) => b.maxTs - a.maxTs || a.row - b.row || a.col - b.col)
    .map((agg) => ({
      row_key: agg.row,
      col_key: agg.col,
      max_ts: agg.maxTs,
      n: agg.n,
      heard: agg.heard,
      best_rssi: agg.bestRssi,
      best_snr: agg.bestSnr,
    }));
  return cellsFromAggRows(rows, nowMs, cap).cells;
}

/**
 * SQLite's multi-argument max() returns NULL if any argument is NULL.
 * A scan with fewer than 8 nodes would otherwise lose every reading.
 * Missing slots are ignored; an all-null scan stays NULL.
 */
function nullSafeSlotMax(field: 'rssi' | 'snr'): string {
  const present: string[] = [];
  const values: string[] = [];
  for (let i = 0; i < NODE_SLOTS; i++) {
    const extract = `json_extract(nodes, '$[${i}].${field}')`;
    present.push(`${extract} IS NOT NULL`);
    values.push(`IFNULL(CAST(${extract} AS REAL), -1e300)`);
  }
  return `CASE WHEN ${present.join(' OR ')} THEN MAX(${values.join(', ')}) ELSE NULL END`;
}

/**
 * One grouped read. Binds: row spacing, odd-row offset, column spacing,
 * minimum timestamp, cap+1. Latitude and longitude are inputs to the cell
 * key only. They are not selected.
 */
export function overviewAggregateSql(): string {
  const rssiMax = nullSafeSlotMax('rssi');
  const snrMax = nullSafeSlotMax('snr');
  return `
SELECT
  row_key,
  col_key,
  MAX(timestamp) AS max_ts,
  COUNT(*) AS n,
  SUM(heard) AS heard,
  MAX(rssi) AS best_rssi,
  MAX(snr) AS best_snr
FROM (
  SELECT
    CAST(ROUND(latitude / ?1) AS INTEGER) AS row_key,
    CAST(ROUND(
      (longitude - CASE
        WHEN (ABS(CAST(ROUND(latitude / ?1) AS INTEGER)) % 2) = 1 THEN ?2
        ELSE 0
      END) / ?3
    ) AS INTEGER) AS col_key,
    timestamp,
    CASE WHEN ${rssiMax} IS NOT NULL OR ${snrMax} IS NOT NULL THEN 1 ELSE 0 END AS heard,
    ${rssiMax} AS rssi,
    ${snrMax} AS snr
  FROM scans
  WHERE timestamp >= ?4
) AS keyed
GROUP BY row_key, col_key
ORDER BY max_ts DESC
LIMIT ?5
`.trim();
}

export function overviewAggregateBinds(nowMs: number, cap = OVERVIEW_CELL_CAP): number[] {
  const grid = overviewGrid();
  const minTs = nowMs - OVERVIEW_LOOKBACK_DAYS * DAY_MS;
  return [grid.rowSpace, grid.halfCol, grid.colSpace, minTs, cap + 1];
}

export function overviewCacheAction(ageMs: number | null): OverviewCacheAction {
  if (ageMs == null) return 'miss';
  if (!Number.isFinite(ageMs)) return 'stale';
  if (ageMs < 0) return 'miss';
  if (ageMs < OVERVIEW_FRESH_MS) return 'fresh';
  if (ageMs < OVERVIEW_FRESH_MS + OVERVIEW_STALE_MS) return 'stale';
  return 'miss';
}

/** Stable cache URL. The query string is dropped so it cannot shard the cache. */
export function overviewCacheKey(requestUrl: string): string {
  const url = new URL(requestUrl);
  url.pathname = OVERVIEW_PATH;
  url.search = '';
  url.hash = '';
  return url.toString();
}

export function workerOverviewCache(): OverviewCache {
  return {
    async match(key: string): Promise<OverviewCacheEntry | null> {
      try {
        const hit = await caches.default.match(new Request(key, { method: 'GET' }));
        if (!hit) return null;
        const storedAt = Number(hit.headers.get('X-Cached-At') || '');
        const body = await hit.text();
        return { body, storedAtMs: storedAt };
      } catch {
        return null;
      }
    },
    async put(key: string, entry: OverviewCacheEntry): Promise<void> {
      try {
        const response = new Response(entry.body, {
          headers: {
            'Content-Type': 'application/json',
            'Cache-Control': OVERVIEW_STORE_CACHE_CONTROL,
            'X-Cached-At': String(entry.storedAtMs),
          },
        });
        await caches.default.put(new Request(key, { method: 'GET' }), response);
      } catch {
        // caches.default may be unavailable in local wrangler.
      }
    },
  };
}

async function overviewEtag(body: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(body));
  const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
  return `"${hex.slice(0, 16)}"`;
}

function clientResponse(
  body: string | null,
  status: number,
  corsHeaders: Record<string, string>,
  etag: string
): Response {
  const headers: Record<string, string> = {
    ...corsHeaders,
    'Cache-Control': OVERVIEW_CACHE_CONTROL,
    ETag: etag,
  };
  if (body != null) headers['Content-Type'] = 'application/json';
  return new Response(body, { status, headers });
}

export async function serveCoverageOverview(args: {
  nowMs: number;
  corsHeaders: Record<string, string>;
  loadRows: OverviewLoader;
  cache: OverviewCache;
  cacheKey: string;
  bypassCache?: boolean;
  waitUntil?: (promise: Promise<unknown>) => void;
  ifNoneMatch?: string | null;
}): Promise<Response> {
  const refresh = async (): Promise<Response> => {
    const rows = await args.loadRows(args.nowMs);
    const payload = buildOverviewPayload(rows, args.nowMs);
    await args.cache.put(args.cacheKey, { body: payload.body, storedAtMs: args.nowMs });
    const etag = await overviewEtag(payload.body);
    if (args.ifNoneMatch && args.ifNoneMatch === etag) {
      return clientResponse(null, 304, args.corsHeaders, etag);
    }
    return clientResponse(payload.body, 200, args.corsHeaders, etag);
  };

  if (!args.bypassCache) {
    const hit = await args.cache.match(args.cacheKey);
    if (hit && hit.body) {
      const age = Number.isFinite(hit.storedAtMs) ? args.nowMs - hit.storedAtMs : Number.NaN;
      const action = overviewCacheAction(age);
      if (action === 'fresh' || action === 'stale') {
        if (action === 'stale' && args.waitUntil) {
          const refreshPromise = refresh().then(() => undefined);
          args.waitUntil(refreshPromise.catch(() => undefined));
        }
        const etag = await overviewEtag(hit.body);
        if (args.ifNoneMatch && args.ifNoneMatch === etag) {
          return clientResponse(null, 304, args.corsHeaders, etag);
        }
        return clientResponse(hit.body, 200, args.corsHeaders, etag);
      }
    }
  }

  return refresh();
}
