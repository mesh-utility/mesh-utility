/**
 * Mesh Utility Cloudflare Worker
 * Handles scan data ingestion and commits to GitHub repository
 */

import { batchCommitToGitHub, getGitHubFileContent } from './github';
import { ScanBatcher } from './batch';
import {
  buildCoverageQueries,
  buildHistoryQueries,
  coverageZoneAccepted,
  dedupeCoverageRows,
  HISTORY_PAGE_SIZE_DEFAULT,
  HISTORY_PAGE_SIZE_MAX,
  mergeHistoryRows,
  parsePolygon,
  planHistoryPage,
  pointInRing,
  prepareAreaQuery,
  resolveGeoBounds,
  type BoundQuery,
  type HistoryChunk,
} from './area_query';
import {
  listScanDaysDesc,
  timestampRangeForDays,
  trackMeta,
  type RowsReadTracker,
  type ScanDayRow,
} from './scan_days';
import {
  OVERVIEW_LOOKBACK_DAYS,
  overviewAggregateBinds,
  overviewAggregateSql,
  overviewCacheKey,
  serveCoverageOverview,
  workerOverviewCache,
  type OverviewAggRow,
} from './coverage_overview';

export interface Env {
  DB: D1Database;
  GITHUB_TOKEN: string;
  GITHUB_REPO: string; // Format: "owner/repo"
  GITHUB_BRANCH: string;
  ALLOWED_ORIGINS: string;
  SCAN_BATCH: DurableObjectNamespace;
  /** Local/dev only: when "1", expose X-D1-Rows-Read on read endpoints. */
  DEBUG_ROWS?: string;
}

export interface ScanPayload {
  radioId: string;
  observerName?: string;
  timestamp: number;
  location: {
    lat: number;
    lon: number;
    altitude?: number;
  };
  nodes: Array<{
    nodeId: string;
    name?: string;
    observerName?: string;
    rssi: number;
    snr: number;
    snrIn?: number;
  }>;
}

const HEX_SIZE = 0.0007;
const LNG_SCALE = 1.2;
const ROW_SPACING = HEX_SIZE * 1.5;
const COL_SPACING = HEX_SIZE * Math.sqrt(3) * LNG_SCALE;
const MASTER_CSV_PATH = 'scans.csv';
const DELETE_CHALLENGE_PREFIX = 'mesh-delete-v1';
const DELETE_CHALLENGE_TTL_MS = 5 * 60 * 1000;
const DELETE_CHALLENGE_CLOCK_SKEW_MS = 30 * 1000;

type DayRow = { day: string };
type NodeEntry = {
  nodeId?: string;
  name?: string;
  observerName?: string;
  rssi?: number;
  snr?: number;
  snrIn?: number;
};
type StoredScanRow = {
  id?: number;
  radioId: string;
  timestamp: number;
  latitude: number;
  longitude: number;
  altitude?: number | null;
  nodes: string;
};
type D1RunMeta = {
  changes?: number;
};
type D1RunResultLike = {
  meta?: D1RunMeta;
};

function parseDaysLimit(raw: string | null, fallback: number): number {
  if (raw == null) return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(0, Math.min(parsed, 365));
}

function parsePositiveInt(raw: string | null, fallback: number, max: number): number {
  if (raw == null) return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) return fallback;
  return Math.max(1, Math.min(parsed, max));
}

/** Max calendar days /coverage will scan even when days=0 (all). Prevents bind storms. */
const COVERAGE_MAX_DAYS = OVERVIEW_LOOKBACK_DAYS;

function wantsDebugRows(request: Request, env: Env): boolean {
  const url = new URL(request.url);
  return env.DEBUG_ROWS === '1' || url.searchParams.get('_debug') === '1';
}

function withDebugRows(
  headers: Record<string, string>,
  tracker: RowsReadTracker | null,
  enabled: boolean
): Record<string, string> {
  if (enabled && tracker) {
    headers['X-D1-Rows-Read'] = String(tracker.rowsRead);
  }
  return headers;
}

async function sha256Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest('SHA-256', data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function cacheKeyRequest(request: Request, cacheUrl?: URL): Request {
  const url = cacheUrl ? new URL(cacheUrl.toString()) : new URL(request.url);
  url.searchParams.delete('_debug');
  return new Request(url.toString(), { method: 'GET' });
}

async function cachedJsonResponse(
  request: Request,
  corsHeaders: Record<string, string>,
  body: string,
  cacheControl: string,
  extraHeaders: Record<string, string> = {},
  cacheUrl?: URL
): Promise<Response> {
  const etag = `"${(await sha256Hex(body)).slice(0, 16)}"`;
  const inm = request.headers.get('If-None-Match');
  if (inm && inm === etag) {
    return new Response(null, {
      status: 304,
      headers: { ...corsHeaders, ETag: etag, 'Cache-Control': cacheControl },
    });
  }
  const headers: Record<string, string> = {
    ...corsHeaders,
    'Content-Type': 'application/json',
    'Cache-Control': cacheControl,
    ETag: etag,
    ...extraHeaders,
  };
  const response = new Response(body, { headers });
  storeCachedGet(cacheKeyRequest(request, cacheUrl), response);
  return response;
}

function storeCachedGet(cacheKey: Request, response: Response): void {
  try {
    const cache = caches.default;
    // fire-and-forget; ignore failures in local/miniflare without Cache
    void cache.put(cacheKey, response.clone()).catch(() => {});
  } catch {
    // caches.default may be unavailable in some local contexts
  }
}

function withCorsResponse(response: Response, corsHeaders: Record<string, string>): Response {
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(corsHeaders)) headers.set(key, value);
  return new Response(response.body, { status: response.status, headers });
}

async function readAreaQueries(
  env: Env,
  tracker: RowsReadTracker,
  queries: BoundQuery[]
): Promise<StoredScanRow[]> {
  if (queries.length === 0) return [];
  if (queries.length === 1) {
    const query = queries[0];
    const result = trackMeta(
      tracker,
      await env.DB.prepare(query.sql).bind(...query.binds).all()
    );
    return (result.results || []) as StoredScanRow[];
  }
  const statements = queries.map((query) => env.DB.prepare(query.sql).bind(...query.binds));
  const results = await env.DB.batch(statements);
  const rows: StoredScanRow[] = [];
  for (const result of results) {
    trackMeta(tracker, result as { meta?: { rows_read?: number } });
    rows.push(...((result.results || []) as StoredScanRow[]));
  }
  return rows;
}

async function matchCachedGet(
  request: Request,
  corsHeaders: Record<string, string>,
  cacheUrl?: URL
): Promise<Response | null> {
  try {
    const cache = caches.default;
    const cacheKey = cacheKeyRequest(request, cacheUrl);
    const hit = await cache.match(cacheKey);
    if (!hit) return null;
    const etag = hit.headers.get('ETag');
    const inm = request.headers.get('If-None-Match');
    if (inm && etag && inm === etag) {
      return new Response(null, {
        status: 304,
        headers: {
          ...corsHeaders,
          ETag: etag,
          'Cache-Control': hit.headers.get('Cache-Control') || 'public, max-age=60',
        },
      });
    }
    // Re-attach CORS for browser callers
    const headers = new Headers(hit.headers);
    for (const [k, v] of Object.entries(corsHeaders)) headers.set(k, v);
    return new Response(hit.body, { status: hit.status, headers });
  } catch {
    return null;
  }
}


function parseNodeEntries(raw: string): NodeEntry[] {
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? (parsed as NodeEntry[]) : [];
  } catch {
    return [];
  }
}

function scanRowToNdjsonLines(row: StoredScanRow, includeDeadzones: boolean): string[] {
  const nodes = parseNodeEntries(row.nodes);
  if (nodes.length === 0) {
    if (!includeDeadzones) return [];
    return [
      JSON.stringify({
        radioId: row.radioId,
        timestamp: row.timestamp,
        latitude: row.latitude,
        longitude: row.longitude,
        altitude: row.altitude,
        nodeId: '',
        senderName: null,
        receiverName: null,
        rssi: null,
        snr: null,
        snrIn: null,
        receivedAt: new Date(row.timestamp).toISOString(),
      }),
    ];
  }
  return nodes.map((node) =>
    JSON.stringify({
      radioId: row.radioId,
      timestamp: row.timestamp,
      latitude: row.latitude,
      longitude: row.longitude,
      altitude: row.altitude,
      nodeId: typeof node?.nodeId === 'string' ? node.nodeId : '',
      senderName: typeof node?.name === 'string' ? node.name : null,
      receiverName: typeof node?.observerName === 'string' ? node.observerName : null,
      rssi: typeof node?.rssi === 'number' ? node.rssi : null,
      snr: typeof node?.snr === 'number' ? node.snr : null,
      snrIn: typeof node?.snrIn === 'number' ? node.snrIn : null,
      receivedAt: new Date(row.timestamp).toISOString(),
    })
  );
}

function originMatchesPattern(origin: string, pattern: string): boolean {
  const normalizedOrigin = origin.trim().toLowerCase();
  const normalizedPattern = pattern.trim().toLowerCase();
  if (!normalizedOrigin || !normalizedPattern) return false;
  if (!normalizedPattern.includes('*')) {
    return normalizedOrigin === normalizedPattern;
  }
  // Supports simple wildcard patterns such as:
  // - https://*.mesh-utility-tracker.pages.dev
  const escaped = normalizedPattern.replace(/[.+?^${}()|[\]\\]/g, '\\$&');
  const regexSource = `^${escaped.replace(/\*/g, '.*')}$`;
  return new RegExp(regexSource).test(normalizedOrigin);
}

function buildCorsHeaders(origin: string, allowedOrigins: string[]): Record<string, string> {
  const matchedOrigin = origin
    ? allowedOrigins.find((allowed) => originMatchesPattern(origin, allowed))
    : null;

  const headers: Record<string, string> = {
    'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    Vary: 'Origin',
  };

  if (matchedOrigin && origin) {
    headers['Access-Control-Allow-Origin'] = origin;
    headers['Access-Control-Allow-Credentials'] = 'true';
    return headers;
  }

  // Non-browser/native callers usually have no Origin header.
  headers['Access-Control-Allow-Origin'] = '*';
  return headers;
}

/** Strip a single leading /api so zone route mesh-utility.org/api/* maps to existing handlers. */
function stripApiPrefix(request: Request): { request: Request; url: URL } {
  const url = new URL(request.url);
  if (url.pathname === '/api') {
    url.pathname = '/';
  } else if (url.pathname.startsWith('/api/')) {
    url.pathname = url.pathname.slice(4) || '/';
  } else {
    return { request, url };
  }
  return { request: new Request(url.toString(), request), url };
}

async function loadOverviewRows(env: Env, nowMs: number): Promise<OverviewAggRow[]> {
  const result = await env.DB.prepare(overviewAggregateSql())
    .bind(...overviewAggregateBinds(nowMs))
    .all();
  return ((result.results || []) as OverviewAggRow[]).map((row) => ({
    row_key: row.row_key,
    col_key: row.col_key,
    max_ts: row.max_ts,
    n: row.n,
    heard: row.heard,
    best_rssi: row.best_rssi,
    best_snr: row.best_snr,
  }));
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const stripped = stripApiPrefix(request);
    request = stripped.request;
    const url = stripped.url;
    const origin = request.headers.get('Origin') || '';
    
    // CORS handling
    const allowedOrigins = env.ALLOWED_ORIGINS
      .split(',')
      .map((origin) => origin.trim())
      .filter((origin) => origin.length > 0);
    const corsHeaders = buildCorsHeaders(origin, allowedOrigins);

    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: corsHeaders });
    }

    try {
      // Health check
      if (url.pathname === '/health') {
        return new Response(JSON.stringify({ status: 'ok' }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Upload scan data
      if (url.pathname === '/scans' && request.method === 'POST') {
        const scans: ScanPayload[] = await request.json();
        
        // Validate scan data
        if (!Array.isArray(scans) || scans.length === 0) {
          return new Response(JSON.stringify({ error: 'Invalid scan data' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        // Get or create batcher instance
        const batcherId = env.SCAN_BATCH.idFromName('global-batcher');
        const batcher = env.SCAN_BATCH.get(batcherId);
        
        // Add scans to batch
        const batchResponse = await batcher.fetch(request.url, {
          method: 'POST',
          body: JSON.stringify(scans),
          headers: {
            'Content-Type': 'application/json',
            'X-GitHub-Token': env.GITHUB_TOKEN,
            'X-GitHub-Repo': env.GITHUB_REPO,
            'X-GitHub-Branch': env.GITHUB_BRANCH || 'main',
          },
        });

        return new Response(await batchResponse.text(), {
          status: batchResponse.status,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // List available history days (JSON index).
      if (
        (url.pathname === '/history' || url.pathname === '/history/index.json') &&
        request.method === 'GET'
      ) {
        const debug = wantsDebugRows(request, env);
        const tracker: RowsReadTracker = { rowsRead: 0 };
        const cached = await matchCachedGet(request, corsHeaders);
        if (cached && !debug) {
          return cached;
        }

        const dayRows = await listScanDaysDesc(env.DB, tracker);
        const days = dayRows.map((row) => row.day);
        const body = JSON.stringify(days);
        return cachedJsonResponse(
          request,
          corsHeaders,
          body,
          'public, max-age=120, s-maxage=300',
          withDebugRows({}, tracker, debug)
        );
      }

      // Coarse worldwide coverage. Same cache short-circuit as the other
      // reads, the same 90-day ceiling, and no query parameters to widen it.
      if (url.pathname === '/coverage/overview' && request.method === 'GET') {
        const nowMs = Date.now();
        return serveCoverageOverview({
          nowMs,
          corsHeaders,
          bypassCache: wantsDebugRows(request, env),
          ifNoneMatch: request.headers.get('If-None-Match'),
          cacheKey: overviewCacheKey(url.toString()),
          waitUntil: (promise) => ctx.waitUntil(promise),
          cache: workerOverviewCache(),
          loadRows: (generatedAt) => loadOverviewRows(env, generatedAt),
        });
      }

      // Fast aggregated coverage endpoint for map rendering.
      if (
        (url.pathname === '/coverage' || url.pathname === '/coverage.json') &&
        request.method === 'GET'
      ) {
        const debug = wantsDebugRows(request, env);
        const tracker: RowsReadTracker = { rowsRead: 0 };
        const geo = resolveGeoBounds(url);
        if (geo.error) return withCorsResponse(geo.error, corsHeaders);
        const polygon = parsePolygon(url.searchParams.get('polygon'));
        if (polygon.error) return withCorsResponse(polygon.error, corsHeaders);
        // Bbox and division edges are rounded outward to 0.1° so the cache key
        // and the SQL box match. Radius queries keep the exact URL.
        const prepared = prepareAreaQuery(url, geo, true);
        if (!debug) {
          const cached = await matchCachedGet(
            request,
            corsHeaders,
            prepared.cacheUrl ?? undefined
          );
          if (cached) return cached;
        }
        if (geo.empty) {
          return cachedJsonResponse(
            request,
            corsHeaders,
            '[]',
            'public, max-age=60, s-maxage=180',
            withDebugRows({}, tracker, debug),
            prepared.cacheUrl ?? undefined
          );
        }

        const maxDays = parseDaysLimit(url.searchParams.get('days'), 7);
        const deadzoneMaxDays = parseDaysLimit(
          url.searchParams.get('deadzoneDays'),
          maxDays
        );

        const allDayRows = await listScanDaysDesc(env.DB, tracker);
        // days=0 means "all", but cap to COVERAGE_MAX_DAYS to avoid huge scans / bind storms.
        const takeDays = (n: number): ScanDayRow[] => {
          if (n === 0) return allDayRows.slice(0, COVERAGE_MAX_DAYS);
          return allDayRows.slice(0, n);
        };
        const selectedDayRows = takeDays(maxDays);
        const selectedDeadzoneDayRows = takeDays(deadzoneMaxDays);
        const selectedDays = selectedDayRows.map((r) => r.day);
        const selectedDeadzoneDays = selectedDeadzoneDayRows.map((r) => r.day);

        // Union of selected days for the SQL window (by day string), then timestamp range.
        const windowDaySet = new Set<string>([...selectedDays, ...selectedDeadzoneDays]);
        const queryWindowRows = allDayRows.filter((r) => windowDaySet.has(r.day));

        if (queryWindowRows.length === 0) {
          const body = JSON.stringify([]);
          return cachedJsonResponse(
            request,
            corsHeaders,
            body,
            'public, max-age=60, s-maxage=180',
            withDebugRows({}, tracker, debug),
            prepared.cacheUrl ?? undefined
          );
        }

        const range = timestampRangeForDays(queryWindowRows);
        if (range == null) {
          return new Response(JSON.stringify({ error: 'invalid day range' }), {
            status: 500,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        // Use timestamp range (index-friendly) instead of date(...) IN (...).
        const coverageQueries = buildCoverageQueries({
          ranges: prepared.ranges,
          minTs: range.minTs,
          maxTs: range.maxTs,
        });
        let scanRows = await readAreaQueries(env, tracker, coverageQueries);
        if (coverageQueries.length > 1) scanRows = dedupeCoverageRows(scanRows);

        const selectedDaySet = new Set(selectedDays);
        const selectedDeadzoneDaySet = new Set(selectedDeadzoneDays);

type CoverageAgg = {
  id: string;
  centerLat: number;
  centerLng: number;
  radiusMeters: number;
  avgRssi: number | null;
  avgSnr: number | null;
  scanCount: number;
  lastScannedTs: number;
  hasNodes: boolean;
  polygon: [number, number][];
  radioId?: string;
  totalRssi: number;
  rssiCount: number;
  totalSnr: number;
  snrCount: number;
        };

        const zoneMap = new Map<string, CoverageAgg>();
        const capZones = geo.kind === 'bbox' || geo.kind === 'division';
        let coverageTruncated = false;

        for (const row of scanRows) {
          if (
            polygon.ring &&
            !pointInRing(Number(row.longitude), Number(row.latitude), polygon.ring)
          ) {
            continue;
          }
          const nodes = parseNodeEntries(row.nodes);
          const rowDay = new Date(Number(row.timestamp || 0))
            .toISOString()
            .slice(0, 10);

          const repeaterNodes = nodes.filter(
            (node) => typeof node?.nodeId === 'string' && node.nodeId.trim().length > 0
          );
          const isDeadLike = repeaterNodes.length === 0;
          const keep = isDeadLike
            ? selectedDeadzoneDaySet.has(rowDay)
            : selectedDaySet.has(rowDay);
          if (!keep) {
            continue;
          }

          const { snapLat, snapLng } = snapToHexGrid(row.latitude, row.longitude);
          const id = `${snapLat.toFixed(6)}:${snapLng.toFixed(6)}`;
          let agg = zoneMap.get(id);
          if (!agg) {
            const decision = coverageZoneAccepted(zoneMap.size, true, capZones);
            if (!decision.accept) {
              coverageTruncated = true;
              break;
            }
            agg = {
              id,
              centerLat: snapLat,
              centerLng: snapLng,
              radiusMeters: 100,
              avgRssi: null,
              avgSnr: null,
              scanCount: 0,
              lastScannedTs: 0,
              hasNodes: false,
              polygon: getHexVertices(snapLat, snapLng),
              radioId: row.radioId,
              totalRssi: 0,
              rssiCount: 0,
              totalSnr: 0,
              snrCount: 0,
            };
            zoneMap.set(id, agg);
          }

          agg.lastScannedTs = Math.max(agg.lastScannedTs, Number(row.timestamp || 0));

          if (repeaterNodes.length === 0) {
            agg.scanCount += 1;
            continue;
          }

          // Dead zone = no response at all. Only mark hasNodes when a
          // repeater entry carries a numeric RSSI (a real hearing).
          for (const node of repeaterNodes) {
            if (typeof node?.rssi !== 'number') continue;
            agg.hasNodes = true;
            const rssi = node.rssi;
            const snr = typeof node?.snr === 'number' ? node.snr : null;
            agg.totalRssi += rssi;
            agg.rssiCount += 1;
            agg.avgRssi = agg.totalRssi / agg.rssiCount;
            if (snr != null) {
              agg.totalSnr += snr;
              agg.snrCount += 1;
              agg.avgSnr = agg.totalSnr / agg.snrCount;
            }
            agg.scanCount += 1;
          }
        }

        const zones = Array.from(zoneMap.values()).map((agg) => ({
          id: agg.id,
          centerLat: agg.centerLat,
          centerLng: agg.centerLng,
          radiusMeters: agg.radiusMeters,
          avgRssi: agg.avgRssi,
          avgSnr: agg.avgSnr,
          scanCount: agg.scanCount,
          lastScanned: new Date(agg.lastScannedTs || Date.now()).toISOString(),
          isDeadZone: !agg.hasNodes,
          polygon: agg.polygon,
          radioId: agg.radioId ?? null,
        }));

        const body = JSON.stringify(zones);
        const coverageExtra = withDebugRows(
          coverageTruncated ? { 'X-Coverage-Truncated': '1' } : {},
          tracker,
          debug
        );
        // A truncated map is partial. Do not store it.
        if (coverageTruncated) {
          return new Response(body, {
            headers: {
              ...corsHeaders,
              'Content-Type': 'application/json',
              'Cache-Control': 'no-store',
              ...coverageExtra,
            },
          });
        }
        return cachedJsonResponse(
          request,
          corsHeaders,
          body,
          'public, max-age=60, s-maxage=180',
          coverageExtra,
          prepared.cacheUrl ?? undefined
        );
      }

      // Fetch scans for a specific day (NDJSON format)
      if (url.pathname.startsWith('/history/') && request.method === 'GET') {
        const day = url.pathname.split('/')[2].replace('.ndjson', '');
        // Validate date format (YYYY-MM-DD)
        if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) {
          return new Response(JSON.stringify({ error: 'Invalid date format' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        const geo = resolveGeoBounds(url);
        if (geo.error) return withCorsResponse(geo.error, corsHeaders);
        const polygon = parsePolygon(url.searchParams.get('polygon'));
        if (polygon.error) return withCorsResponse(polygon.error, corsHeaders);

        const deadzoneMaxDays = parseDaysLimit(
          url.searchParams.get('deadzoneDays'),
          0
        );
        const pageSize = parsePositiveInt(url.searchParams.get('pageSize'), HISTORY_PAGE_SIZE_DEFAULT, HISTORY_PAGE_SIZE_MAX);
        const debug = wantsDebugRows(request, env);
        const tracker: RowsReadTracker = { rowsRead: 0 };
        const cursorTimestampRaw = Number.parseInt(url.searchParams.get('cursorTimestamp') || '', 10);
        const cursorIdRaw = Number.parseInt(url.searchParams.get('cursorId') || '', 10);
        const hasCursor = Number.isFinite(cursorTimestampRaw) && Number.isFinite(cursorIdRaw);
        // First page of a bbox/division query is cached under the rounded key.
        // Cursor pages and radius/worldwide history stay uncached, as before.
        const prepared = prepareAreaQuery(url, geo, !hasCursor);
        if (prepared.cacheUrl && !debug) {
          const cached = await matchCachedGet(request, corsHeaders, prepared.cacheUrl);
          if (cached) return cached;
        }

        const historyHeaders = (hasMore: boolean): Record<string, string> => withDebugRows({
          ...corsHeaders,
          'Content-Type': 'application/x-ndjson',
          'Cache-Control': 'public, max-age=120, s-maxage=300',
          'X-Page-Size': `${pageSize}`,
          'X-Has-More': hasMore ? '1' : '0',
        }, tracker, debug);

        if (geo.empty) {
          const response = new Response('', { headers: historyHeaders(false) });
          if (prepared.cacheUrl && !debug) {
            storeCachedGet(cacheKeyRequest(request, prepared.cacheUrl), response);
          }
          return response;
        }

        // Calculate Unix timestamps for the day range (full UTC day, ms-inclusive).
        // BUGFIX: old T23:59:59Z dropped timestamps with ms > 0 in the last second.
        const dayStart = new Date(day + 'T00:00:00Z').getTime();
        const dayEnd = dayStart + 86_400_000 - 1;
        const historyQueries = buildHistoryQueries({
          ranges: prepared.ranges,
          dayStart,
          dayEnd,
          pageSize,
          cursorTimestamp: hasCursor ? cursorTimestampRaw : undefined,
          cursorId: hasCursor ? cursorIdRaw : undefined,
        });
        const fetched = await readAreaQueries(env, tracker, historyQueries);
        // Multi-range reads are UNION ALL chunks. Merge to one (timestamp, id) page.
        const merged = mergeHistoryRows([fetched], pageSize);

        let includeDeadzonesForDay = true;
        if (deadzoneMaxDays > 0) {
          const dayRows = await listScanDaysDesc(env.DB, tracker);
          const selectedDeadzoneDays = dayRows
            .slice(0, deadzoneMaxDays)
            .map((row) => row.day);
          includeDeadzonesForDay = selectedDeadzoneDays.includes(day);
        }

        const encoder = new TextEncoder();
        const chunks: HistoryChunk[] = [];
        const texts: Array<string | null> = [];
        for (const row of merged.rows) {
          if (
            polygon.ring &&
            !pointInRing(Number(row.longitude), Number(row.latitude), polygon.ring)
          ) {
            chunks.push(null);
            texts.push(null);
            continue;
          }
          const lines = scanRowToNdjsonLines(row, includeDeadzonesForDay);
          if (lines.length === 0) {
            chunks.push(null);
            texts.push(null);
            continue;
          }
          const text = lines.join('\n');
          texts.push(text);
          chunks.push({ bytes: encoder.encode(text).length });
        }
        // X-Has-More follows the SQL page unless the 1 MB budget stops early.
        // The cursor is the underlying scan, so a polygon-filtered page can be short.
        const plan = planHistoryPage(chunks, merged.hasMore);
        const parts: string[] = [];
        for (let i = 0; i < texts.length; i++) {
          if (!plan.emit[i] || texts[i] == null) continue;
          parts.push(texts[i] as string);
        }
        const ndjson = parts.join('\n');
        const cursorRow = plan.cursorIndex >= 0 ? merged.rows[plan.cursorIndex] : null;
        const headers = historyHeaders(plan.hasMore);
        if (plan.hasMore && cursorRow != null) {
          headers['X-Next-Cursor-Timestamp'] = `${cursorRow.timestamp}`;
          headers['X-Next-Cursor-Id'] = `${cursorRow.id ?? 0}`;
        }

        const response = new Response(ndjson, { headers });
        if (prepared.cacheUrl && !debug) {
          storeCachedGet(cacheKeyRequest(request, prepared.cacheUrl), response);
        }
        return response;
      }

      if (url.pathname === '/maintenance/deadzones/cleanup' && request.method === 'POST') {
        const body = await request.json() as { hexes?: unknown };
        if (!Array.isArray(body.hexes)) {
          return new Response(JSON.stringify({ error: 'hexes array required' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }
        const requestedHexes = body.hexes
          .map((value) => typeof value === 'string' ? value.trim() : '')
          .filter((value) => value.length > 0);
        const uniqueHexes = Array.from(new Set(requestedHexes));
        if (uniqueHexes.length === 0) {
          return new Response(JSON.stringify({ deleted: 0, hexes: 0 }), {
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }
        const deleted = await cleanupDeadzonesForHexes(env.DB, uniqueHexes);
        return new Response(
          JSON.stringify({ deleted, hexes: uniqueHexes.length }),
          {
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          }
        );
      }

      // Request signed deletion challenge
      if (url.pathname === '/delete/challenge' && request.method === 'POST') {
        const body = await request.json() as { radioId?: string; publicKey?: string };
        const radioId = normalizeRadioId(body.radioId);
        const publicKey = normalizeHex(body.publicKey);

        if (!radioId || !isHex(publicKey, 64)) {
          return new Response(JSON.stringify({ error: 'radioId and publicKey are required' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        const derivedRadioId = radioIdFromPublicKeyHex(publicKey);
        if (derivedRadioId !== radioId) {
          return new Response(JSON.stringify({ error: 'radioId does not match publicKey prefix' }), {
            status: 403,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        const challenge = createDeleteChallenge(radioId);
        return new Response(JSON.stringify(challenge), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Delete user data after signed ownership verification
      if (url.pathname.startsWith('/delete/') && request.method === 'POST') {
        const radioId = normalizeRadioId(url.pathname.split('/')[2]);
        if (!radioId) {
          return new Response(JSON.stringify({ error: 'radioId required' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        const body = await request.json() as {
          publicKey?: string;
          challenge?: string;
          signature?: string;
        };

        const publicKey = normalizeHex(body.publicKey);
        const challenge = typeof body.challenge === 'string' ? body.challenge.trim() : '';
        const signature = normalizeHex(body.signature);

        if (!isHex(publicKey, 64) || !isHex(signature, 128) || challenge.length === 0) {
          return new Response(JSON.stringify({ error: 'publicKey, challenge, and signature are required' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        const derivedRadioId = radioIdFromPublicKeyHex(publicKey);
        if (derivedRadioId !== radioId) {
          return new Response(JSON.stringify({ error: 'radioId ownership verification failed' }), {
            status: 403,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        const parsedChallenge = parseDeleteChallenge(challenge);
        if (!parsedChallenge || parsedChallenge.radioId !== radioId) {
          return new Response(JSON.stringify({ error: 'invalid delete challenge' }), {
            status: 403,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        const now = Date.now();
        if (
          parsedChallenge.expiresAt < now - DELETE_CHALLENGE_CLOCK_SKEW_MS ||
          parsedChallenge.expiresAt > now + DELETE_CHALLENGE_TTL_MS + DELETE_CHALLENGE_CLOCK_SKEW_MS
        ) {
          return new Response(JSON.stringify({ error: 'delete challenge expired' }), {
            status: 403,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        const verified = await verifyDeleteSignature(
          hexToBytes(publicKey),
          new TextEncoder().encode(challenge),
          hexToBytes(signature)
        );
        if (!verified) {
          return new Response(JSON.stringify({ error: 'invalid signature for radio ownership proof' }), {
            status: 403,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        let pendingRemoved = 0;
        try {
          const batcherId = env.SCAN_BATCH.idFromName('global-batcher');
          const batcher = env.SCAN_BATCH.get(batcherId);
          const batchDeleteRes = await batcher.fetch(`${url.origin}/delete/${encodeURIComponent(radioId)}`, {
            method: 'POST',
          });
          if (batchDeleteRes.ok) {
            const batchDeleteJson = await batchDeleteRes.json() as { removed?: number };
            pendingRemoved = Number(batchDeleteJson.removed || 0);
          }
        } catch (error) {
          console.error('Failed to remove pending scans from batcher:', error);
        }

        const d1DeleteResult = await env.DB.prepare('DELETE FROM scans WHERE radioId = ?')
          .bind(radioId)
          .run();
        const d1Deleted = Number((d1DeleteResult as D1RunResultLike)?.meta?.changes || 0);

        const csvUpdate = await removeRadioRowsFromMasterCsv(env, radioId);

        const deletionRecord = {
          radioId,
          publicKey,
          deletedAt: new Date().toISOString(),
          action: 'deletion',
          ownership: 'radio-signature-verified',
          challengeExpiresAt: parsedChallenge.expiresAt,
          d1Deleted,
          pendingRemoved,
          csvRowsRemoved: csvUpdate.removedRows,
        };

        const date = new Date().toISOString().split('T')[0];
        const files: Array<{ path: string; content: string }> = [
          {
            path: `deletions/${date}/${radioId}.json`,
            content: JSON.stringify(deletionRecord, null, 2),
          },
        ];

        if (csvUpdate.updatedContent) {
          files.push({
            path: MASTER_CSV_PATH,
            content: csvUpdate.updatedContent,
          });
        }

        await batchCommitToGitHub(
          env,
          files,
          `Delete data for radio ${radioId.substring(0, 8)} (${csvUpdate.removedRows} rows removed from ${MASTER_CSV_PATH})`
        );

        return new Response(
          JSON.stringify({
            success: true,
            radioId,
            d1Deleted,
            pendingRemoved,
            csvRowsRemoved: csvUpdate.removedRows,
          }),
          {
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          }
        );
      }

      return new Response('Not Found', { status: 404, headers: corsHeaders });
    } catch (error) {
      console.error('Worker error:', error);
      return new Response(
        JSON.stringify({ error: error instanceof Error ? error.message : 'Internal Server Error' }),
        {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        }
      );
    }
  },
};

function normalizeRadioId(value: unknown): string {
  return typeof value === 'string' ? value.trim().toUpperCase() : '';
}

function normalizeHex(value: unknown): string {
  return typeof value === 'string' ? value.trim().toUpperCase() : '';
}

function isHex(value: string, expectedLength: number): boolean {
  return value.length === expectedLength && /^[0-9A-F]+$/.test(value);
}

function radioIdFromPublicKeyHex(publicKey: string): string {
  return normalizeHex(publicKey).slice(0, 8);
}

function snapToHexGrid(lat: number, lon: number): { snapLat: number; snapLng: number } {
  const row = Math.round(lat / ROW_SPACING);
  const isOddRow = Math.abs(row) % 2 === 1;
  const offset = isOddRow ? COL_SPACING / 2 : 0;
  const col = Math.round((lon - offset) / COL_SPACING);
  return {
    snapLat: row * ROW_SPACING,
    snapLng: col * COL_SPACING + offset,
  };
}

function getHexVertices(centerLat: number, centerLng: number): [number, number][] {
  const vertices: [number, number][] = [];
  for (let i = 0; i < 6; i++) {
    const angleDeg = 60 * i - 30;
    const angleRad = (Math.PI / 180) * angleDeg;
    const lat = centerLat + HEX_SIZE * Math.sin(angleRad);
    const lng = centerLng + HEX_SIZE * Math.cos(angleRad) * LNG_SCALE;
    vertices.push([lat, lng]);
  }
  return vertices;
}

type CleanupRow = {
  id?: number;
  latitude: number;
  longitude: number;
  nodes: string;
};

async function cleanupDeadzonesForHexes(
  db: D1Database,
  hexes: string[]
): Promise<number> {
  let totalDeleted = 0;
  const searchRange = 0.01;
  for (const key of hexes) {
    const parsed = parseHexKey(key);
    if (!parsed) continue;
    const rows = await db.prepare(`
      SELECT id, latitude, longitude, nodes
      FROM scans
      WHERE latitude BETWEEN ? AND ?
        AND longitude BETWEEN ? AND ?
    `)
      .bind(
        parsed.lat - searchRange,
        parsed.lat + searchRange,
        parsed.lng - searchRange,
        parsed.lng + searchRange
      )
      .all();
    const candidates = rows.results as CleanupRow[];
    let hasSuccess = false;
    const deadzoneRowIds: number[] = [];
    for (const row of candidates) {
      const rowHex = snappedHexKey(row.latitude, row.longitude);
      if (rowHex !== key) continue;
      const nodes = parseNodeEntries(row.nodes);
      if (hasSuccessfulNodes(nodes)) {
        hasSuccess = true;
        continue;
      }
      if (typeof row.id === 'number') {
        deadzoneRowIds.push(row.id);
      }
    }
    if (!hasSuccess || deadzoneRowIds.length === 0) {
      continue;
    }
    for (const id of deadzoneRowIds) {
      const deleteRes = await db.prepare('DELETE FROM scans WHERE id = ?')
        .bind(id)
        .run();
      totalDeleted += Number((deleteRes as D1RunResultLike)?.meta?.changes || 0);
    }
  }
  return totalDeleted;
}

function parseHexKey(value: string): { lat: number; lng: number } | null {
  const parts = value.split(':');
  if (parts.length !== 2) return null;
  const lat = Number(parts[0]);
  const lng = Number(parts[1]);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return null;
  }
  return { lat, lng };
}

function snappedHexKey(lat: number, lng: number): string {
  const { snapLat, snapLng } = snapToHexGrid(lat, lng);
  return `${snapLat.toFixed(6)}:${snapLng.toFixed(6)}`;
}

function hasSuccessfulNodes(nodes: NodeEntry[]): boolean {
  for (const node of nodes) {
    if (!node) continue;
    if (typeof node.nodeId !== 'string' || node.nodeId.trim().length === 0) {
      continue;
    }
    if (typeof node.rssi !== 'number' || !Number.isFinite(node.rssi)) {
      continue;
    }
    return true;
  }
  return false;
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
    .toUpperCase();
}

function hexToBytes(hex: string): Uint8Array {
  const clean = normalizeHex(hex);
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < clean.length; i += 2) {
    out[i / 2] = Number.parseInt(clean.slice(i, i + 2), 16);
  }
  return out;
}

function createDeleteChallenge(radioId: string): { challenge: string; expiresAt: number } {
  const nonceBytes = new Uint8Array(16);
  crypto.getRandomValues(nonceBytes);
  const nonce = bytesToHex(nonceBytes);
  const expiresAt = Date.now() + DELETE_CHALLENGE_TTL_MS;
  return {
    challenge: `${DELETE_CHALLENGE_PREFIX}:${radioId}:${nonce}:${expiresAt}`,
    expiresAt,
  };
}

function parseDeleteChallenge(challenge: string): { radioId: string; expiresAt: number } | null {
  const parts = challenge.split(':');
  if (parts.length !== 4) {
    return null;
  }

  const [prefix, radioId, nonce, expiresAtRaw] = parts;
  if (prefix !== DELETE_CHALLENGE_PREFIX) {
    return null;
  }

  const normalizedRadioId = normalizeRadioId(radioId);
  if (!isHex(normalizedRadioId, 8)) {
    return null;
  }

  if (!isHex(normalizeHex(nonce), 32)) {
    return null;
  }

  const expiresAt = Number.parseInt(expiresAtRaw, 10);
  if (!Number.isFinite(expiresAt)) {
    return null;
  }

  return { radioId: normalizedRadioId, expiresAt };
}

async function verifyDeleteSignature(
  publicKey: Uint8Array,
  message: Uint8Array,
  signature: Uint8Array
): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey(
      'raw',
      publicKey,
      'Ed25519',
      false,
      ['verify']
    );
    return await crypto.subtle.verify('Ed25519', key, signature, message);
  } catch (error) {
    console.error('Failed to verify delete signature:', error);
    return false;
  }
}

async function removeRadioRowsFromMasterCsv(
  env: Env,
  radioId: string
): Promise<{ updatedContent: string | null; removedRows: number }> {
  const existingCsv = await getGitHubFileContent(env, MASTER_CSV_PATH);
  if (!existingCsv) {
    return { updatedContent: null, removedRows: 0 };
  }

  const normalizedCsv = existingCsv.replace(/\r\n/g, '\n').trimEnd();
  if (!normalizedCsv) {
    return { updatedContent: null, removedRows: 0 };
  }

  const lines = normalizedCsv.split('\n');
  const header = lines[0];
  const headerColumns = parseCsvLine(header);
  const radioIdIndex = headerColumns.indexOf('radioId');
  if (radioIdIndex === -1) {
    throw new Error(`Missing radioId column in ${MASTER_CSV_PATH}`);
  }

  const rowIdIndex = headerColumns.indexOf('row_id');
  const keptRows: string[] = [];
  let removedRows = 0;

  for (const line of lines.slice(1)) {
    if (line.trim().length === 0) {
      continue;
    }

    const columns = parseCsvLine(line);
    const rowRadioId = normalizeRadioId(columns[radioIdIndex] || '');
    if (rowRadioId === radioId) {
      removedRows++;
      continue;
    }

    keptRows.push(line);
  }

  if (removedRows === 0) {
    return { updatedContent: null, removedRows: 0 };
  }

  let outputRows = keptRows;
  if (rowIdIndex === 0) {
    outputRows = keptRows.map((line, index) => {
      const columns = parseCsvLine(line);
      columns[0] = String(index + 1);
      return toCsvLine(columns);
    });
  }

  return {
    updatedContent: `${header}\n${outputRows.join('\n')}\n`,
    removedRows,
  };
}

function parseCsvLine(line: string): string[] {
  const values: string[] = [];
  let current = '';
  let inQuotes = false;

  for (let i = 0; i < line.length; i++) {
    const char = line[i];

    if (char === '"') {
      const nextChar = line[i + 1];
      if (inQuotes && nextChar === '"') {
        current += '"';
        i++;
        continue;
      }
      inQuotes = !inQuotes;
      continue;
    }

    if (char === ',' && !inQuotes) {
      values.push(current);
      current = '';
      continue;
    }

    current += char;
  }

  values.push(current);
  return values;
}

function toCsvLine(values: string[]): string {
  return values.map((value) => escapeCsvValue(value)).join(',');
}

function escapeCsvValue(value: string): string {
  const escaped = value.replace(/"/g, '""');
  if (/[",\n\r]/.test(escaped)) {
    return `"${escaped}"`;
  }
  return escaped;
}

// Export Durable Object class
export { ScanBatcher };
