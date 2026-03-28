/**
 * Mesh Utility Cloudflare Worker
 * Handles scan data ingestion and commits to GitHub repository
 */

import { batchCommitToGitHub, getGitHubFileContent } from './github';
import { ScanBatcher } from './batch';

export interface Env {
  DB: D1Database;
  GITHUB_TOKEN: string;
  GITHUB_REPO: string; // Format: "owner/repo"
  GITHUB_BRANCH: string;
  ALLOWED_ORIGINS: string;
  SCAN_BATCH: DurableObjectNamespace;
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

function parseNodeEntries(raw: string): NodeEntry[] {
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? (parsed as NodeEntry[]) : [];
  } catch {
    return [];
  }
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

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
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
        // Get distinct dates from scans
        const result = await env.DB.prepare(`
          SELECT DISTINCT date(timestamp / 1000, 'unixepoch') as day
          FROM scans
          ORDER BY day DESC
        `).all();

        const days = (result.results as DayRow[]).map((row) => row.day);

        return new Response(JSON.stringify(days), {
          headers: {
            ...corsHeaders,
            'Content-Type': 'application/json',
            'Cache-Control': 'public, max-age=120, s-maxage=300',
          },
        });
      }

      // Fast aggregated coverage endpoint for map rendering.
      if (
        (url.pathname === '/coverage' || url.pathname === '/coverage.json') &&
        request.method === 'GET'
      ) {
        const maxDays = parseDaysLimit(url.searchParams.get('days'), 7);
        const deadzoneMaxDays = parseDaysLimit(
          url.searchParams.get('deadzoneDays'),
          maxDays
        );

        const dayRows = await env.DB.prepare(`
          SELECT DISTINCT date(timestamp / 1000, 'unixepoch') as day
          FROM scans
          ORDER BY day DESC
        `).all();
        const allDays = (dayRows.results as DayRow[]).map((row) => String(row.day));
        const selectedDays = maxDays === 0 ? allDays : allDays.slice(0, maxDays);
        const selectedDeadzoneDays =
          deadzoneMaxDays === 0 ? allDays : allDays.slice(0, deadzoneMaxDays);
        const queryWindowDays = allDays.slice(
          0,
          Math.max(selectedDays.length, selectedDeadzoneDays.length)
        );

        if (queryWindowDays.length === 0) {
          return new Response(JSON.stringify([]), {
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        const dayPlaceholders = queryWindowDays.map(() => '?').join(',');
        const scans = await env.DB.prepare(`
          SELECT radioId, timestamp, latitude, longitude, nodes
          FROM scans
          WHERE date(timestamp / 1000, 'unixepoch') IN (${dayPlaceholders})
          ORDER BY timestamp ASC
        `)
          .bind(...queryWindowDays)
          .all();

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
        };

        const zoneMap = new Map<string, CoverageAgg>();

        for (const row of scans.results as StoredScanRow[]) {
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
            };
            zoneMap.set(id, agg);
          }

          agg.lastScannedTs = Math.max(agg.lastScannedTs, Number(row.timestamp || 0));

          if (repeaterNodes.length === 0) {
            agg.scanCount += 1;
            continue;
          }

          agg.hasNodes = true;
          for (const node of repeaterNodes) {
            if (typeof node?.rssi !== 'number') continue;
            const rssi = node.rssi;
            const snr = typeof node?.snr === 'number' ? node.snr : null;
            agg.avgRssi = agg.avgRssi == null ? rssi : Math.max(agg.avgRssi, rssi);
            if (snr != null) {
              agg.avgSnr = agg.avgSnr == null ? snr : Math.max(agg.avgSnr, snr);
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

        return new Response(JSON.stringify(zones), {
          headers: {
            ...corsHeaders,
            'Content-Type': 'application/json',
            'Cache-Control': 'public, max-age=60, s-maxage=180',
          },
        });
      }

      // Fetch scans for a specific day (NDJSON format)
      if (url.pathname.startsWith('/history/') && request.method === 'GET') {
        const day = url.pathname.split('/')[2].replace('.ndjson', '');
        const deadzoneMaxDays = parseDaysLimit(
          url.searchParams.get('deadzoneDays'),
          0
        );
        const pageSize = parsePositiveInt(url.searchParams.get('pageSize'), 2000, 5000);
        const cursorTimestampRaw = Number.parseInt(url.searchParams.get('cursorTimestamp') || '', 10);
        const cursorIdRaw = Number.parseInt(url.searchParams.get('cursorId') || '', 10);
        const hasCursor = Number.isFinite(cursorTimestampRaw) && Number.isFinite(cursorIdRaw);
        
        // Validate date format (YYYY-MM-DD)
        if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) {
          return new Response(JSON.stringify({ error: 'Invalid date format' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        // Calculate Unix timestamps for the day range
        const dayStart = new Date(day + 'T00:00:00Z').getTime();
        const dayEnd = new Date(day + 'T23:59:59Z').getTime();

        const scans = hasCursor
          ? await env.DB.prepare(`
              SELECT id, radioId, timestamp, latitude, longitude, altitude, nodes
              FROM scans
              WHERE timestamp >= ? AND timestamp <= ?
                AND (timestamp > ? OR (timestamp = ? AND id > ?))
              ORDER BY timestamp ASC, id ASC
              LIMIT ?
            `)
              .bind(
                dayStart,
                dayEnd,
                cursorTimestampRaw,
                cursorTimestampRaw,
                cursorIdRaw,
                pageSize + 1
              )
              .all()
          : await env.DB.prepare(`
              SELECT id, radioId, timestamp, latitude, longitude, altitude, nodes
              FROM scans
              WHERE timestamp >= ? AND timestamp <= ?
              ORDER BY timestamp ASC, id ASC
              LIMIT ?
            `)
              .bind(dayStart, dayEnd, pageSize + 1)
              .all();

        let includeDeadzonesForDay = true;
        if (deadzoneMaxDays > 0) {
          const dayRows = await env.DB.prepare(`
            SELECT DISTINCT date(timestamp / 1000, 'unixepoch') as day
            FROM scans
            ORDER BY day DESC
          `).all();
          const allDays = (dayRows.results as DayRow[]).map((row) => String(row.day));
          const selectedDeadzoneDays = allDays.slice(0, deadzoneMaxDays);
          includeDeadzonesForDay = selectedDeadzoneDays.includes(day);
        }

        const pageRows = scans.results as StoredScanRow[];
        const hasMore = pageRows.length > pageSize;
        const rowsForPage = hasMore ? pageRows.slice(0, pageSize) : pageRows;
        const lastRow = rowsForPage.length > 0 ? rowsForPage[rowsForPage.length - 1] : null;

        // Convert to NDJSON format
        const ndjsonLines = rowsForPage.flatMap((row) => {
          const nodes = parseNodeEntries(row.nodes);

          if (nodes.length === 0) {
            if (!includeDeadzonesForDay) {
              return [];
            }
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
        });

        const ndjson = ndjsonLines.join('\n');

        const historyHeaders: Record<string, string> = {
          ...corsHeaders,
          'Content-Type': 'application/x-ndjson',
          'Cache-Control': 'public, max-age=120, s-maxage=300',
          'X-Page-Size': `${pageSize}`,
          'X-Has-More': hasMore ? '1' : '0',
        };
        if (hasMore && lastRow != null) {
          historyHeaders['X-Next-Cursor-Timestamp'] = `${lastRow.timestamp}`;
          historyHeaders['X-Next-Cursor-Id'] = `${lastRow.id ?? 0}`;
        }

        return new Response(ndjson, { headers: historyHeaders });
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
