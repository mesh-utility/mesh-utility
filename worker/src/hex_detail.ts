/**
 * Indexed per-hex coverage with full Alpha-24 fields.
 *
 * Hex ids are the fixed scale-1 odd-row grid (`row:col`) used by
 * lib/src/services/grid.dart and the former coverage tile index. Cells are
 * never resized, merged, or moved. Day filters read hex_detail_day so 7/14/30/
 * 90/365/All work without scanning raw `scans` rows.
 */

export const HEX_SIZE = 0.0007;
export const LNG_SCALE = 1.2;
/** Dart's `1.7320508075688772`, identical to Math.sqrt(3). */
export const SQRT3 = 1.7320508075688772;
export const ROW_SPACING = HEX_SIZE * 1.5;
export const COL_SPACING = HEX_SIZE * SQRT3 * LNG_SCALE;
export const NODE_CAP = 24;
export const HEX_DETAIL_PATH_PREFIX = '/coverage/hex/';
export const HEX_WORLD_PATH = '/coverage/hex-world';
export const HEX_VIEWPORT_PATH = '/coverage/hex-viewport';
export const WORLD_CACHE_CONTROL =
  'public, max-age=300, stale-while-revalidate=3600';
export const VIEWPORT_CACHE_CONTROL =
  'public, max-age=60, stale-while-revalidate=300';
export const DETAIL_CACHE_CONTROL = 'public, max-age=30, stale-while-revalidate=300';
export const WORLD_STORE_CACHE_CONTROL = 'public, max-age=3900';
/** Uncompressed JSON soft cap. Hexes are never dropped; nodes may be omitted. */
export const WORLD_SOFT_BYTE_CAP = 1_500_000;

const DAY_MS = 86_400_000;

export type HexNodeRole = 'repeater' | 'observer' | 'companion';

export type HexNode = {
  i: string;
  n?: string;
  role?: HexNodeRole;
  sn?: string;
  rn?: string;
  t: number;
  s?: number | null;
  r?: number | null;
  ls?: number | null;
  lr?: number | null;
  c: number;
};

export type HexDetailFields = {
  hex_id: string;
  row: number;
  col: number;
  scan_count: number;
  first_ts: number;
  last_ts: number;
  best_snr: number | null;
  best_rssi: number | null;
  last_snr: number | null;
  last_rssi: number | null;
  last_altitude: number | null;
  last_lat: number;
  last_lng: number;
  last_node_id: string | null;
  last_node_name: string | null;
  nodes: HexNode[];
};

export type HexDetailRow = Omit<HexDetailFields, 'nodes'> & {
  nodes_json: string | null;
  day?: string;
  updated_ms?: number;
};

export type ScanNodeLike = {
  nodeId?: string;
  name?: string;
  observerName?: string;
  observerId?: string;
  role?: string;
  type?: string | number;
  rssi?: number | null;
  snr?: number | null;
  snrIn?: number | null;
};

export type ScanLike = {
  radioId?: string;
  observerName?: string;
  timestamp: number;
  latitude: number;
  longitude: number;
  altitude?: number | null;
  nodes?: ScanNodeLike[] | string | null;
};

export type NameCatalog = {
  byId: Map<string, string>;
  byPrefix: Map<string, string>;
};

export type HexCacheEntry = { body: string; storedAtMs: number };

export interface HexCache {
  match(key: string): Promise<HexCacheEntry | null>;
  put(key: string, entry: HexCacheEntry): Promise<void>;
}

/** Half away from zero. Matches Dart `round` and SQLite `ROUND`. */
export function roundHalfAwayFromZero(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.sign(value) * Math.round(Math.abs(value));
}

export function fineHexAt(
  lat: number,
  lng: number
): { row: number; col: number; id: string; centerLat: number; centerLng: number } {
  const row = roundHalfAwayFromZero(lat / ROW_SPACING);
  const odd = Math.abs(row) % 2 === 1;
  const offset = odd ? COL_SPACING / 2 : 0;
  const col = roundHalfAwayFromZero((lng - offset) / COL_SPACING);
  const center = hexCellCenter(row, col);
  return {
    row,
    col,
    id: hexIdFor(row, col),
    centerLat: center.lat,
    centerLng: center.lng,
  };
}

/** Fixed odd-row pointy-top center. Identical to lib/src/services/grid.dart. */
export function hexCellCenter(row: number, col: number): { lat: number; lng: number } {
  const odd = Math.abs(row) % 2 === 1;
  return {
    lat: row * ROW_SPACING,
    lng: col * COL_SPACING + (odd ? COL_SPACING / 2 : 0),
  };
}

export function hexIdFor(row: number, col: number): string {
  return `${row}:${col}`;
}

export function parseHexId(id: string): { row: number; col: number } | null {
  const raw = id.trim().replace(/^hex:/, '').replace(/^tile:/, '');
  const parts = raw.split(':');
  if (parts.length !== 2) return null;
  const row = Number(parts[0]);
  const col = Number(parts[1]);
  if (!Number.isFinite(row) || !Number.isFinite(col)) return null;
  return { row: roundHalfAwayFromZero(row), col: roundHalfAwayFromZero(col) };
}

export function utcDayFromTs(ts: number): string {
  return new Date(ts).toISOString().slice(0, 10);
}

/** Inclusive lower UTC day for a rolling lookback. Null means All days. */
export function minDayForLookback(days: number, nowMs: number): string | null {
  if (!Number.isFinite(days) || days <= 0) return null;
  const safe = Math.min(Math.trunc(days), 3650);
  return utcDayFromTs(nowMs - safe * DAY_MS);
}

export function parseDaysParam(raw: string | null, fallback = 0): number {
  if (raw == null || raw === '') return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed)) return fallback;
  if (parsed <= 0) return 0;
  return Math.min(parsed, 3650);
}

export function parseNodes(raw: unknown): ScanNodeLike[] {
  if (Array.isArray(raw)) return raw as ScanNodeLike[];
  if (typeof raw === 'string' && raw.trim()) {
    try {
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? (parsed as ScanNodeLike[]) : [];
    } catch {
      return [];
    }
  }
  return [];
}

function asRole(raw: unknown): HexNodeRole | undefined {
  const v = String(raw ?? '').trim().toLowerCase();
  if (v === 'repeater' || v === 'observer' || v === 'companion') return v;
  return undefined;
}

/** Compact hex form of an id or id-shaped label (separators stripped). */
export function compactHexId(value: string): string {
  return value.replace(/[\s:\-_]/g, '').toUpperCase();
}

/** True when [value] is only a hex id of at least 8 digits, not a word that uses A-F. */
export function isHexIdShapedLabel(value: string): boolean {
  const compact = compactHexId(value);
  if (compact.length < 8 || compact.length > 64) return false;
  return /^[0-9A-F]+$/.test(compact);
}

/**
 * Empty, "unknown", id-shaped short/full pubkey labels, or a name equal to
 * the node id / its prefix. Human names that merely contain hex letters stay names.
 */
export function isPlaceholderNodeName(name: unknown, nodeId?: string | null): boolean {
  if (typeof name !== 'string') return true;
  const trimmed = name.trim();
  if (!trimmed) return true;
  const lower = trimmed.toLowerCase();
  if (lower === 'unknown' || lower.startsWith('unknown (')) return true;
  if (!isHexIdShapedLabel(trimmed)) return false;
  const nameHex = compactHexId(trimmed);
  const idHex = compactHexId((nodeId || '').trim());
  if (!idHex) return true;
  return nameHex === idHex || idHex.startsWith(nameHex) || nameHex.startsWith(idHex);
}

export function usableNodeName(raw: unknown, nodeId?: string | null): string | undefined {
  if (typeof raw !== 'string') return undefined;
  const name = raw.trim();
  if (!name) return undefined;
  if (isPlaceholderNodeName(name, nodeId)) return undefined;
  return name;
}

function prefix8(id: string): string {
  const u = id.trim().toUpperCase();
  return u.length >= 8 ? u.slice(0, 8) : u;
}

export function parseHexNodes(raw: unknown): HexNode[] {
  if (Array.isArray(raw)) {
    const out: HexNode[] = [];
    for (const entry of raw as Array<Record<string, unknown>>) {
      if (!entry || typeof entry !== 'object') continue;
      const i = typeof entry.i === 'string' ? entry.i : typeof entry.id === 'string' ? entry.id : typeof entry.nodeId === 'string' ? entry.nodeId : '';
      if (!i) continue;
      const t = finiteNum(entry.t ?? entry.lastTs) ?? 0;
      out.push({
        i,
        n: usableNodeName(entry.n ?? entry.name, i),
        role: asRole(entry.role),
        sn: usableNodeName(entry.sn ?? entry.senderName, i),
        rn: usableNodeName(entry.rn ?? entry.receiverName ?? entry.observerName),
        t,
        s: finiteNum(entry.s ?? entry.bestSnr ?? entry.snr),
        r: finiteNum(entry.r ?? entry.bestRssi ?? entry.rssi),
        ls: finiteNum(entry.ls ?? entry.lastSnr),
        lr: finiteNum(entry.lr ?? entry.lastRssi),
        c: Number(entry.c ?? entry.count) || 1,
      });
    }
    return out;
  }
  if (typeof raw === 'string' && raw.trim()) {
    try {
      return parseHexNodes(JSON.parse(raw));
    } catch {
      return [];
    }
  }
  return [];
}

function finiteNum(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string' && value.trim() !== '') {
    const n = Number(value);
    if (Number.isFinite(n)) return n;
  }
  return null;
}

function betterSignal(next: number | null, prev: number | null): number | null {
  if (next == null) return prev;
  if (prev == null) return next;
  return next > prev ? next : prev;
}

function pickName(
  newerTs: boolean,
  incoming?: string,
  existing?: string,
  nodeId?: string | null,
): string | undefined {
  const inc = usableNodeName(incoming, nodeId);
  const prev = usableNodeName(existing, nodeId);
  if (newerTs) return inc || prev;
  return prev || inc;
}

export function mergeHexNodes(existing: HexNode[], incoming: HexNode[]): HexNode[] {
  const byId = new Map<string, HexNode>();
  for (const n of existing) {
    if (!n?.i) continue;
    byId.set(n.i, { ...n });
  }
  for (const n of incoming) {
    if (!n?.i) continue;
    const prev = byId.get(n.i);
    if (!prev) {
      byId.set(n.i, { ...n, c: n.c || 1 });
      continue;
    }
    const incomingIsLast = n.t >= prev.t;
    const next: HexNode = {
      i: n.i,
      n: pickName(incomingIsLast, n.n, prev.n, n.i),
      role: incomingIsLast ? n.role || prev.role : prev.role || n.role,
      sn: pickName(incomingIsLast, n.sn, prev.sn, n.i),
      rn: pickName(incomingIsLast, n.rn, prev.rn),
      t: Math.max(prev.t, n.t),
      s: betterSignal(n.s ?? null, prev.s ?? null),
      r: betterSignal(n.r ?? null, prev.r ?? null),
      ls: incomingIsLast ? (n.ls ?? n.s ?? prev.ls ?? null) : (prev.ls ?? prev.s ?? n.ls ?? null),
      lr: incomingIsLast ? (n.lr ?? n.r ?? prev.lr ?? null) : (prev.lr ?? prev.r ?? n.lr ?? null),
      c: (prev.c || 0) + (n.c || 1),
    };
    byId.set(n.i, next);
  }
  return [...byId.values()].sort((a, b) => {
    if (a.role === 'observer' && b.role !== 'observer') return 1;
    if (b.role === 'observer' && a.role !== 'observer') return -1;
    return b.t - a.t || b.c - a.c || a.i.localeCompare(b.i);
  });
}

export function nodesFromScan(scan: ScanLike): HexNode[] {
  const timestamp = Number(scan.timestamp) || 0;
  const heard = parseNodes(scan.nodes);
  const observerId = typeof scan.radioId === 'string' ? scan.radioId.trim() : '';
  let observerName = usableNodeName(scan.observerName, observerId);
  const out: HexNode[] = [];
  let bestSnr: number | null = null;
  let bestRssi: number | null = null;
  for (const node of heard) {
    const observerFromNodeId = typeof node.observerId === 'string' ? node.observerId.trim() : observerId;
    const fromNode = usableNodeName(node.observerName, observerFromNodeId);
    if (fromNode && !observerName) observerName = fromNode;
  }
  for (const node of heard) {
    const id = typeof node.nodeId === 'string' ? node.nodeId.trim() : '';
    if (!id) continue;
    const snr = finiteNum(node.snr);
    const rssi = finiteNum(node.rssi);
    bestSnr = betterSignal(snr, bestSnr);
    bestRssi = betterSignal(rssi, bestRssi);
    const name = usableNodeName(node.name, id);
    const role = asRole(node.role) ?? asRole(node.type) ?? 'repeater';
    out.push({
      i: id,
      n: name,
      role,
      sn: name,
      rn: observerName,
      t: timestamp,
      s: snr,
      r: rssi,
      ls: snr,
      lr: rssi,
      c: 1,
    });
  }
  if (observerId) {
    out.push({
      i: observerId,
      n: observerName,
      role: 'observer',
      rn: observerName,
      t: timestamp,
      s: bestSnr,
      r: bestRssi,
      ls: bestSnr,
      lr: bestRssi,
      c: 1,
    });
  }
  return mergeHexNodes([], out);
}

export function emptyNameCatalog(): NameCatalog {
  return { byId: new Map(), byPrefix: new Map() };
}

export function addNameToCatalog(catalog: NameCatalog, id: string | null | undefined, name: string | undefined): void {
  const trimmedId = (id || '').trim();
  const usable = usableNodeName(name, trimmedId);
  if (!trimmedId || !usable) return;
  const previous = catalog.byId.get(trimmedId);
  if (previous && !isPlaceholderNodeName(previous, trimmedId)) {
    // Keep an existing real name; do not replace it (incoming is already real here
    // only when usable). Prefer the first real name unless none is stored yet.
    return;
  }
  catalog.byId.set(trimmedId, usable);
  const pref = prefix8(trimmedId);
  if (pref) catalog.byPrefix.set(pref, usable);
}

export function collectNameCatalog(scans: ScanLike[]): NameCatalog {
  const catalog = emptyNameCatalog();
  for (const scan of scans) {
    addNameToCatalog(catalog, scan.radioId, scan.observerName);
    for (const node of parseNodes(scan.nodes)) {
      addNameToCatalog(catalog, typeof node.nodeId === 'string' ? node.nodeId : '', node.name);
      addNameToCatalog(catalog, scan.radioId, node.observerName);
      if (typeof node.observerId === 'string') {
        addNameToCatalog(catalog, node.observerId, node.observerName);
      }
    }
  }
  return catalog;
}

export function lookupCatalogName(catalog: NameCatalog, id: string | null | undefined): string | undefined {
  const trimmed = (id || '').trim();
  if (!trimmed) return undefined;
  return catalog.byId.get(trimmed) || catalog.byPrefix.get(prefix8(trimmed));
}

export function applyNameCatalog(fields: HexDetailFields, catalog: NameCatalog): HexDetailFields {
  const nodes = fields.nodes.map((node) => {
    const resolved = lookupCatalogName(catalog, node.i);
    const n = usableNodeName(node.n, node.i) || resolved;
    const sn = node.role === 'observer' ? usableNodeName(node.sn, node.i) : usableNodeName(node.sn, node.i) || n || resolved;
    const rn = node.role === 'observer'
      ? usableNodeName(node.rn, node.i) || n || resolved
      : usableNodeName(node.rn) || lookupCatalogName(catalog, '') || usableNodeName(node.rn);
    return { ...node, n: n || undefined, sn: sn || undefined, rn: rn || undefined };
  });
  // Fill receiver names on heard nodes from the observer entry when present.
  const observerName = nodes.find((n) => n.role === 'observer')?.n;
  const filled = observerName
    ? nodes.map((n) => (n.role === 'observer' ? n : { ...n, rn: n.rn || observerName }))
    : nodes;
  const lastHeard = filled.find((n) => n.role !== 'observer') ?? filled[0];
  return {
    ...fields,
    last_node_name: usableNodeName(fields.last_node_name, fields.last_node_id) || lastHeard?.n || null,
    nodes: filled,
  };
}

export function scanDedupeKey(scan: ScanLike): string {
  const radio = (scan.radioId || '').trim().toUpperCase();
  const ts = Number(scan.timestamp) || 0;
  const lat = Number(scan.latitude);
  const lng = Number(scan.longitude);
  return `${radio}|${ts}|${lat}|${lng}`;
}

export function existingScanSelectSql(): string {
  return `SELECT id FROM scans
    WHERE radioId = ? AND timestamp = ?
      AND latitude = ? AND longitude = ?
    LIMIT 1`;
}

export function scanToDetail(scan: ScanLike): HexDetailFields | null {
  const lat = Number(scan.latitude);
  const lng = Number(scan.longitude);
  const ts = Number(scan.timestamp);
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || !Number.isFinite(ts) || ts <= 0) {
    return null;
  }
  const hex = fineHexAt(lat, lng);
  const nodes = nodesFromScan(scan);
  let bestSnr: number | null = null;
  let bestRssi: number | null = null;
  let lastNodeId: string | null = null;
  let lastNodeName: string | null = null;
  let lastSnr: number | null = null;
  let lastRssi: number | null = null;
  for (const n of nodes) {
    if (n.role === 'observer') continue;
    bestSnr = betterSignal(n.s ?? null, bestSnr);
    bestRssi = betterSignal(n.r ?? null, bestRssi);
  }
  const last = nodes.find((n) => n.role !== 'observer') ?? nodes[0];
  if (last) {
    lastNodeId = last.i;
    lastNodeName = last.n ?? null;
    lastSnr = last.ls ?? last.s ?? null;
    lastRssi = last.lr ?? last.r ?? null;
  }
  return {
    hex_id: hex.id,
    row: hex.row,
    col: hex.col,
    scan_count: 1,
    first_ts: ts,
    last_ts: ts,
    best_snr: bestSnr,
    best_rssi: bestRssi,
    last_snr: lastSnr,
    last_rssi: lastRssi,
    last_altitude: finiteNum(scan.altitude),
    last_lat: lat,
    last_lng: lng,
    last_node_id: lastNodeId,
    last_node_name: lastNodeName,
    nodes,
  };
}

export function mergeDetail(
  existing: HexDetailFields | null,
  incoming: HexDetailFields
): HexDetailFields {
  if (!existing) {
    const nodes = mergeHexNodes([], incoming.nodes);
    const lastId = incoming.last_node_id;
    const lastFromNodes = lastId ? nodes.find((n) => n.i === lastId) : undefined;
    return {
      ...incoming,
      last_node_name: usableNodeName(incoming.last_node_name, lastId) || lastFromNodes?.n || null,
      nodes,
    };
  }
  const incomingIsLast = incoming.last_ts >= existing.last_ts;
  const nodes = mergeHexNodes(existing.nodes, incoming.nodes);
  const lastId = incomingIsLast ? incoming.last_node_id : existing.last_node_id;
  const lastFromNodes = lastId ? nodes.find((n) => n.i === lastId) : undefined;
  const fromFields = pickName(
    incomingIsLast,
    incoming.last_node_name ?? undefined,
    existing.last_node_id === incoming.last_node_id || !incomingIsLast
      ? existing.last_node_name ?? undefined
      : undefined,
    lastId,
  );
  return {
    hex_id: existing.hex_id,
    row: existing.row,
    col: existing.col,
    scan_count: existing.scan_count + incoming.scan_count,
    first_ts: Math.min(existing.first_ts, incoming.first_ts),
    last_ts: Math.max(existing.last_ts, incoming.last_ts),
    best_snr: betterSignal(incoming.best_snr, existing.best_snr),
    best_rssi: betterSignal(incoming.best_rssi, existing.best_rssi),
    last_snr: incomingIsLast ? incoming.last_snr : existing.last_snr,
    last_rssi: incomingIsLast ? incoming.last_rssi : existing.last_rssi,
    last_altitude: incomingIsLast ? incoming.last_altitude : existing.last_altitude,
    last_lat: incomingIsLast ? incoming.last_lat : existing.last_lat,
    last_lng: incomingIsLast ? incoming.last_lng : existing.last_lng,
    last_node_id: lastId,
    last_node_name: fromFields || lastFromNodes?.n || null,
    nodes,
  };
}

export function rowToFields(row: HexDetailRow): HexDetailFields {
  return {
    hex_id: row.hex_id,
    row: Number(row.row),
    col: Number(row.col),
    scan_count: Number(row.scan_count) || 0,
    first_ts: Number(row.first_ts) || 0,
    last_ts: Number(row.last_ts) || 0,
    best_snr: finiteNum(row.best_snr),
    best_rssi: finiteNum(row.best_rssi),
    last_snr: finiteNum(row.last_snr),
    last_rssi: finiteNum(row.last_rssi),
    last_altitude: finiteNum(row.last_altitude),
    last_lat: Number(row.last_lat),
    last_lng: Number(row.last_lng),
    last_node_id: row.last_node_id || null,
    last_node_name: usableNodeName(row.last_node_name, row.last_node_id) || null,
    nodes: parseHexNodes(row.nodes_json),
  };
}

export function fieldsToRow(
  fields: HexDetailFields,
  extra?: { day?: string; updated_ms?: number }
): HexDetailRow {
  return {
    hex_id: fields.hex_id,
    row: fields.row,
    col: fields.col,
    scan_count: fields.scan_count,
    first_ts: fields.first_ts,
    last_ts: fields.last_ts,
    best_snr: fields.best_snr,
    best_rssi: fields.best_rssi,
    last_snr: fields.last_snr,
    last_rssi: fields.last_rssi,
    last_altitude: fields.last_altitude,
    last_lat: fields.last_lat,
    last_lng: fields.last_lng,
    last_node_id: fields.last_node_id,
    last_node_name: fields.last_node_name,
    nodes_json: JSON.stringify(fields.nodes),
    day: extra?.day,
    updated_ms: extra?.updated_ms,
  };
}

export type MemoryHexStore = {
  days: Map<string, HexDetailFields>;
  hexes: Map<string, HexDetailFields>;
  seen: Set<string>;
};

export function createMemoryHexStore(): MemoryHexStore {
  return { days: new Map(), hexes: new Map(), seen: new Set() };
}

/** In-memory apply used by tests and as the ingest/backfill merge spec. */
export function applyScanToStore(
  store: MemoryHexStore,
  scan: ScanLike,
  opts?: { dedupe?: boolean }
): { applied: boolean; reason?: string; hexId?: string; day?: string } {
  const detail = scanToDetail(scan);
  if (!detail) return { applied: false, reason: 'invalid' };
  const key = scanDedupeKey(scan);
  if (opts?.dedupe !== false) {
    if (store.seen.has(key)) return { applied: false, reason: 'duplicate', hexId: detail.hex_id };
    store.seen.add(key);
  }
  const day = utcDayFromTs(detail.last_ts);
  const dayKey = `${detail.hex_id}|${day}`;
  store.days.set(dayKey, mergeDetail(store.days.get(dayKey) ?? null, detail));
  store.hexes.set(detail.hex_id, mergeDetail(store.hexes.get(detail.hex_id) ?? null, detail));
  return { applied: true, hexId: detail.hex_id, day };
}

export function aggregateStoreForDays(
  store: MemoryHexStore,
  minDay: string | null
): HexDetailFields[] {
  if (minDay == null) return [...store.hexes.values()];
  const byHex = new Map<string, HexDetailFields>();
  for (const [key, row] of store.days) {
    const day = key.slice(key.lastIndexOf('|') + 1);
    if (day < minDay) continue;
    byHex.set(row.hex_id, mergeDetail(byHex.get(row.hex_id) ?? null, row));
  }
  return [...byHex.values()];
}

/** Compact paint/history payload. `h` entries are fixed-order arrays. */
export function buildHexListPayload(
  rows: HexDetailFields[],
  opts: { days: number; includeNodes?: boolean; softByteCap?: number }
): { body: string; hexCount: number; bytes: number; nodesOmitted: boolean } {
  const includeNodes = opts.includeNodes !== false;
  const cap = opts.softByteCap ?? WORLD_SOFT_BYTE_CAP;
  const pack = (withNodes: boolean) => {
    const h = rows.map((row) => {
      const base: unknown[] = [
        row.row,
        row.col,
        row.scan_count,
        row.last_ts,
        row.best_snr,
        row.best_rssi,
        row.last_snr,
        row.last_rssi,
        row.last_altitude,
        hexCellCenter(row.row, row.col).lat,
        hexCellCenter(row.row, row.col).lng,
        row.last_node_id,
        row.last_node_name,
      ];
      if (withNodes) base.push(row.nodes);
      return base;
    });
    const payload: Record<string, unknown> = {
      v: 1,
      days: opts.days,
      keys: withNodes
        ? 'row,col,n,t,bestSnr,bestRssi,lastSnr,lastRssi,alt,lat,lng,nid,nnm,nodes'
        : 'row,col,n,t,bestSnr,bestRssi,lastSnr,lastRssi,alt,lat,lng,nid,nnm',
      h,
    };
    if (!withNodes && includeNodes) payload.nodesOmitted = true;
    return JSON.stringify(payload);
  };
  let body = pack(includeNodes);
  let nodesOmitted = false;
  if (includeNodes && body.length > cap) {
    body = pack(false);
    nodesOmitted = true;
  }
  return { body, hexCount: rows.length, bytes: body.length, nodesOmitted };
}

export function parseHexListPayload(body: string): HexDetailFields[] {
  const raw = JSON.parse(body) as { v?: number; h?: unknown[] };
  if (!raw || !Array.isArray(raw.h)) return [];
  const out: HexDetailFields[] = [];
  for (const entry of raw.h) {
    if (!Array.isArray(entry) || entry.length < 13) continue;
    const row = Number(entry[0]);
    const col = Number(entry[1]);
    if (!Number.isFinite(row) || !Number.isFinite(col)) continue;
    out.push({
      hex_id: hexIdFor(row, col),
      row,
      col,
      scan_count: Number(entry[2]) || 0,
      first_ts: 0,
      last_ts: Number(entry[3]) || 0,
      best_snr: finiteNum(entry[4]),
      best_rssi: finiteNum(entry[5]),
      last_snr: finiteNum(entry[6]),
      last_rssi: finiteNum(entry[7]),
      last_altitude: finiteNum(entry[8]),
      last_lat: Number(entry[9]),
      last_lng: Number(entry[10]),
      last_node_id: entry[11] == null ? null : String(entry[11]),
      last_node_name: entry[12] == null ? null : String(entry[12]),
      nodes: parseHexNodes(entry[13]),
    });
  }
  return out;
}

export function buildHexDetailPayload(fields: HexDetailFields, days: number): string {
  return JSON.stringify({
    v: 1,
    days,
    hex: {
      id: fields.hex_id,
      row: fields.row,
      col: fields.col,
      scanCount: fields.scan_count,
      firstTs: fields.first_ts,
      lastTs: fields.last_ts,
      bestSnr: fields.best_snr,
      bestRssi: fields.best_rssi,
      lastSnr: fields.last_snr,
      lastRssi: fields.last_rssi,
      altitude: fields.last_altitude,
      lat: hexCellCenter(fields.row, fields.col).lat,
      lng: hexCellCenter(fields.row, fields.col).lng,
      lastLat: fields.last_lat,
      lastLng: fields.last_lng,
      lastNodeId: fields.last_node_id,
      lastNodeName: fields.last_node_name,
      nodes: fields.nodes,
    },
  });
}

export function boundsToRowCol(args: {
  south: number;
  north: number;
  west: number;
  east: number;
}): { rowMin: number; rowMax: number; colMin: number; colMax: number } {
  const south = Math.min(args.south, args.north);
  const north = Math.max(args.south, args.north);
  const west = Math.min(args.west, args.east);
  const east = Math.max(args.west, args.east);
  const rowMin = roundHalfAwayFromZero(south / ROW_SPACING) - 2;
  const rowMax = roundHalfAwayFromZero(north / ROW_SPACING) + 2;
  const colMin = roundHalfAwayFromZero(west / COL_SPACING) - 2;
  const colMax = roundHalfAwayFromZero(east / COL_SPACING) + 2;
  return { rowMin, rowMax, colMin, colMax };
}

export function viewportSelectSql(allDays: boolean): string {
  if (allDays) {
    return `SELECT hex_id, row, col, scan_count, first_ts, last_ts, best_snr, best_rssi,
      last_snr, last_rssi, last_altitude, last_lat, last_lng, last_node_id, last_node_name, nodes_json
      FROM hex_detail
      WHERE row BETWEEN ? AND ? AND col BETWEEN ? AND ?`;
  }
  return `SELECT hex_id, row, col,
      SUM(scan_count) AS scan_count,
      MIN(first_ts) AS first_ts,
      MAX(last_ts) AS last_ts,
      MAX(best_snr) AS best_snr,
      MAX(best_rssi) AS best_rssi
    FROM hex_detail_day
    WHERE day >= ? AND row BETWEEN ? AND ? AND col BETWEEN ? AND ?
    GROUP BY hex_id, row, col`;
}

export function worldSelectSql(allDays: boolean): string {
  if (allDays) {
    return `SELECT hex_id, row, col, scan_count, first_ts, last_ts, best_snr, best_rssi,
      last_snr, last_rssi, last_altitude, last_lat, last_lng, last_node_id, last_node_name, nodes_json
      FROM hex_detail`;
  }
  return `SELECT hex_id, row, col,
      SUM(scan_count) AS scan_count,
      MIN(first_ts) AS first_ts,
      MAX(last_ts) AS last_ts,
      MAX(best_snr) AS best_snr,
      MAX(best_rssi) AS best_rssi
    FROM hex_detail_day
    WHERE day >= ?
    GROUP BY hex_id, row, col`;
}

export function dayRowsForHexesSql(): string {
  return `SELECT hex_id, day, row, col, scan_count, first_ts, last_ts, best_snr, best_rssi,
      last_snr, last_rssi, last_altitude, last_lat, last_lng, last_node_id, last_node_name, nodes_json
    FROM hex_detail_day
    WHERE day >= ? AND hex_id IN (/*ids*/)`;
}

export function expandDayRowSql(ids: string[]): { sql: string; binds: string[] } {
  const placeholders = ids.map(() => '?').join(', ');
  return {
    sql: `SELECT hex_id, day, row, col, scan_count, first_ts, last_ts, best_snr, best_rssi,
      last_snr, last_rssi, last_altitude, last_lat, last_lng, last_node_id, last_node_name, nodes_json
      FROM hex_detail_day
      WHERE day >= ? AND hex_id IN (${placeholders})`,
    binds: ids,
  };
}

export function mergeDayRows(rows: HexDetailRow[]): HexDetailFields[] {
  const byHex = new Map<string, HexDetailFields>();
  for (const row of rows) {
    const fields = rowToFields(row);
    byHex.set(fields.hex_id, mergeDetail(byHex.get(fields.hex_id) ?? null, fields));
  }
  return [...byHex.values()];
}

export type D1Like = {
  prepare: (sql: string) => {
    bind: (...args: unknown[]) => {
      first: <T = Record<string, unknown>>() => Promise<T | null>;
      run: () => Promise<{ meta?: { changes?: number } }>;
      all: <T = Record<string, unknown>>() => Promise<{ results?: T[] }>;
    };
  };
};

const UPSERT_DAY_SQL = `INSERT INTO hex_detail_day (
    hex_id, day, row, col, scan_count, first_ts, last_ts, best_snr, best_rssi,
    last_snr, last_rssi, last_altitude, last_lat, last_lng, last_node_id, last_node_name, nodes_json
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ON CONFLICT(hex_id, day) DO UPDATE SET
    scan_count = excluded.scan_count,
    first_ts = excluded.first_ts,
    last_ts = excluded.last_ts,
    best_snr = excluded.best_snr,
    best_rssi = excluded.best_rssi,
    last_snr = excluded.last_snr,
    last_rssi = excluded.last_rssi,
    last_altitude = excluded.last_altitude,
    last_lat = excluded.last_lat,
    last_lng = excluded.last_lng,
    last_node_id = excluded.last_node_id,
    last_node_name = excluded.last_node_name,
    nodes_json = excluded.nodes_json`;

const UPSERT_HEX_SQL = `INSERT INTO hex_detail (
    hex_id, row, col, scan_count, first_ts, last_ts, best_snr, best_rssi,
    last_snr, last_rssi, last_altitude, last_lat, last_lng, last_node_id, last_node_name, nodes_json, updated_ms
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ON CONFLICT(hex_id) DO UPDATE SET
    scan_count = excluded.scan_count,
    first_ts = excluded.first_ts,
    last_ts = excluded.last_ts,
    best_snr = excluded.best_snr,
    best_rssi = excluded.best_rssi,
    last_snr = excluded.last_snr,
    last_rssi = excluded.last_rssi,
    last_altitude = excluded.last_altitude,
    last_lat = excluded.last_lat,
    last_lng = excluded.last_lng,
    last_node_id = excluded.last_node_id,
    last_node_name = excluded.last_node_name,
    nodes_json = excluded.nodes_json,
    updated_ms = excluded.updated_ms`;

async function bindDay(db: D1Like, fields: HexDetailFields, day: string): Promise<void> {
  const dayRow = fieldsToRow(fields, { day });
  await db
    .prepare(UPSERT_DAY_SQL)
    .bind(
      dayRow.hex_id,
      day,
      dayRow.row,
      dayRow.col,
      dayRow.scan_count,
      dayRow.first_ts,
      dayRow.last_ts,
      dayRow.best_snr,
      dayRow.best_rssi,
      dayRow.last_snr,
      dayRow.last_rssi,
      dayRow.last_altitude,
      dayRow.last_lat,
      dayRow.last_lng,
      dayRow.last_node_id,
      dayRow.last_node_name,
      dayRow.nodes_json
    )
    .run();
}

async function bindHex(db: D1Like, fields: HexDetailFields, nowMs: number): Promise<void> {
  const hexRow = fieldsToRow(fields, { updated_ms: nowMs });
  await db
    .prepare(UPSERT_HEX_SQL)
    .bind(
      hexRow.hex_id,
      hexRow.row,
      hexRow.col,
      hexRow.scan_count,
      hexRow.first_ts,
      hexRow.last_ts,
      hexRow.best_snr,
      hexRow.best_rssi,
      hexRow.last_snr,
      hexRow.last_rssi,
      hexRow.last_altitude,
      hexRow.last_lat,
      hexRow.last_lng,
      hexRow.last_node_id,
      hexRow.last_node_name,
      hexRow.nodes_json,
      nowMs
    )
    .run();
}

export async function findExistingScanId(db: D1Like, scan: ScanLike): Promise<number | null> {
  const radio = (scan.radioId || '').trim().toUpperCase();
  const row = await db
    .prepare(existingScanSelectSql())
    .bind(radio, Number(scan.timestamp) || 0, Number(scan.latitude), Number(scan.longitude))
    .first<{ id: number }>();
  if (row && row.id != null) return Number(row.id);
  return null;
}

async function loadDayAndHex(
  db: D1Like,
  hexId: string,
  day: string
): Promise<{ day: HexDetailFields | null; hex: HexDetailFields | null }> {
  const dayRow = await db
    .prepare(
      `SELECT hex_id, row, col, scan_count, first_ts, last_ts, best_snr, best_rssi,
        last_snr, last_rssi, last_altitude, last_lat, last_lng, last_node_id, last_node_name, nodes_json
       FROM hex_detail_day WHERE hex_id = ? AND day = ?`
    )
    .bind(hexId, day)
    .first<HexDetailRow>();
  const hexRow = await db
    .prepare(
      `SELECT hex_id, row, col, scan_count, first_ts, last_ts, best_snr, best_rssi,
        last_snr, last_rssi, last_altitude, last_lat, last_lng, last_node_id, last_node_name, nodes_json
       FROM hex_detail WHERE hex_id = ?`
    )
    .bind(hexId)
    .first<HexDetailRow>();
  return {
    day: dayRow ? rowToFields(dayRow) : null,
    hex: hexRow ? rowToFields(hexRow) : null,
  };
}

/**
 * Incremental, idempotent ingest: skip exact resubmits (same radio, ts, lat, lng)
 * and merge the new scan into hex_detail_day + hex_detail.
 */
export async function applyScanToHexDetail(
  db: D1Like,
  scan: ScanLike,
  opts?: { nowMs?: number; skipDedupeLookup?: boolean }
): Promise<{ applied: boolean; reason?: string; hexId?: string; day?: string }> {
  const detail = scanToDetail(scan);
  if (!detail) return { applied: false, reason: 'invalid' };
  if (!opts?.skipDedupeLookup) {
    const existing = await findExistingScanId(db, scan);
    if (existing != null) return { applied: false, reason: 'duplicate', hexId: detail.hex_id };
  }
  const nowMs = opts?.nowMs ?? Date.now();
  const day = utcDayFromTs(detail.last_ts);
  const current = await loadDayAndHex(db, detail.hex_id, day);
  const nextDay = mergeDetail(current.day, detail);
  const nextHex = mergeDetail(current.hex, detail);
  await bindDay(db, nextDay, day);
  await bindHex(db, nextHex, nowMs);
  return { applied: true, hexId: detail.hex_id, day };
}

/** After dead-zone rows in a hex are deleted, rebuild that hex from remaining scans. */
export async function recomputeHexFromScans(
  db: D1Like,
  hexId: string,
  nowMs = Date.now()
): Promise<void> {
  const parsed = parseHexId(hexId);
  if (!parsed) return;
  const center = fineHexAt(parsed.row * ROW_SPACING, parsed.col * COL_SPACING);
  // Use the real center; fineHexAt on the already-snapped center is stable.
  const lat = parsed.row * ROW_SPACING;
  const odd = Math.abs(parsed.row) % 2 === 1;
  const lng = parsed.col * COL_SPACING + (odd ? COL_SPACING / 2 : 0);
  const range = 0.01;
  const result = await db
    .prepare(
      `SELECT radioId, timestamp, latitude, longitude, altitude, nodes
       FROM scans WHERE latitude BETWEEN ? AND ? AND longitude BETWEEN ? AND ?`
    )
    .bind(lat - range, lat + range, lng - range, lng + range)
    .all<ScanLike>();
  const store = createMemoryHexStore();
  for (const row of result.results || []) {
    const cell = fineHexAt(Number(row.latitude), Number(row.longitude));
    if (cell.id !== hexId) continue;
    applyScanToStore(store, row, { dedupe: true });
  }
  await db.prepare(`DELETE FROM hex_detail_day WHERE hex_id = ?`).bind(hexId).run();
  await db.prepare(`DELETE FROM hex_detail WHERE hex_id = ?`).bind(hexId).run();
  const hex = store.hexes.get(hexId);
  if (!hex) return;
  for (const [key, fields] of store.days) {
    if (!key.startsWith(`${hexId}|`)) continue;
    const day = key.slice(hexId.length + 1);
    const dayRow = fieldsToRow(fields, { day });
    await db
      .prepare(UPSERT_DAY_SQL)
      .bind(
        dayRow.hex_id,
        day,
        dayRow.row,
        dayRow.col,
        dayRow.scan_count,
        dayRow.first_ts,
        dayRow.last_ts,
        dayRow.best_snr,
        dayRow.best_rssi,
        dayRow.last_snr,
        dayRow.last_rssi,
        dayRow.last_altitude,
        dayRow.last_lat,
        dayRow.last_lng,
        dayRow.last_node_id,
        dayRow.last_node_name,
        dayRow.nodes_json
      )
      .run();
  }
  void center;
  const hexRow = fieldsToRow(hex, { updated_ms: nowMs });
  await db
    .prepare(UPSERT_HEX_SQL)
    .bind(
      hexRow.hex_id,
      hexRow.row,
      hexRow.col,
      hexRow.scan_count,
      hexRow.first_ts,
      hexRow.last_ts,
      hexRow.best_snr,
      hexRow.best_rssi,
      hexRow.last_snr,
      hexRow.last_rssi,
      hexRow.last_altitude,
      hexRow.last_lat,
      hexRow.last_lng,
      hexRow.last_node_id,
      hexRow.last_node_name,
      hexRow.nodes_json,
      nowMs
    )
    .run();
}

/** Bump when world payload semantics change so Cache API does not serve a stale body. */
export const HEX_WORLD_CACHE_VER = 2;

export function hexWorldCacheKey(requestUrl: string, days: number): string {
  const url = new URL(requestUrl);
  url.pathname = HEX_WORLD_PATH;
  url.search = `days=${days}&cv=${HEX_WORLD_CACHE_VER}`;
  url.hash = '';
  return url.toString();
}

export function workerHexCache(): HexCache {
  return {
    async match(key: string): Promise<HexCacheEntry | null> {
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
    async put(key: string, entry: HexCacheEntry): Promise<void> {
      try {
        const response = new Response(entry.body, {
          headers: {
            'Content-Type': 'application/json',
            'Cache-Control': WORLD_STORE_CACHE_CONTROL,
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

async function shaEtag(body: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(body));
  const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
  return `"${hex.slice(0, 16)}"`;
}

function clientResponse(
  body: string | null,
  status: number,
  corsHeaders: Record<string, string>,
  etag: string,
  cacheControl: string
): Response {
  const headers: Record<string, string> = {
    ...corsHeaders,
    'Cache-Control': cacheControl,
    ETag: etag,
  };
  if (body != null) headers['Content-Type'] = 'application/json';
  return new Response(body, { status, headers });
}

export function extractHexIdFromPath(pathname: string): string | null {
  if (!pathname.startsWith(HEX_DETAIL_PATH_PREFIX)) return null;
  const rest = pathname.slice(HEX_DETAIL_PATH_PREFIX.length);
  return parseHexId(decodeURIComponent(rest)) ? decodeURIComponent(rest) : null;
}

export function cacheAction(ageMs: number | null): 'miss' | 'fresh' | 'stale' {
  if (ageMs == null || !Number.isFinite(ageMs) || ageMs < 0) return 'miss';
  if (ageMs < 300_000) return 'fresh';
  if (ageMs < 300_000 + 3_600_000) return 'stale';
  return 'miss';
}

export async function serveCachedJson(args: {
  nowMs: number;
  corsHeaders: Record<string, string>;
  cache?: HexCache;
  cacheKey?: string;
  cacheControl: string;
  bypassCache?: boolean;
  waitUntil?: (promise: Promise<unknown>) => void;
  ifNoneMatch?: string | null;
  load: () => Promise<string>;
}): Promise<Response> {
  const refresh = async (): Promise<Response> => {
    const body = await args.load();
    if (args.cache && args.cacheKey) {
      await args.cache.put(args.cacheKey, { body, storedAtMs: args.nowMs });
    }
    const etag = await shaEtag(body);
    if (args.ifNoneMatch && args.ifNoneMatch === etag) {
      return clientResponse(null, 304, args.corsHeaders, etag, args.cacheControl);
    }
    return clientResponse(body, 200, args.corsHeaders, etag, args.cacheControl);
  };
  if (!args.bypassCache && args.cache && args.cacheKey) {
    const hit = await args.cache.match(args.cacheKey);
    if (hit?.body) {
      const action = cacheAction(
        Number.isFinite(hit.storedAtMs) ? args.nowMs - hit.storedAtMs : null
      );
      if (action === 'fresh' || action === 'stale') {
        if (action === 'stale' && args.waitUntil) {
          args.waitUntil(refresh().then(() => undefined).catch(() => undefined));
        }
        const etag = await shaEtag(hit.body);
        if (args.ifNoneMatch && args.ifNoneMatch === etag) {
          return clientResponse(null, 304, args.corsHeaders, etag, args.cacheControl);
        }
        return clientResponse(hit.body, 200, args.corsHeaders, etag, args.cacheControl);
      }
    }
  }
  return refresh();
}


export async function loadOneHex(
  db: D1Like,
  hexId: string,
  days: number,
  nowMs: number
): Promise<HexDetailFields | null> {
  const parsed = parseHexId(hexId);
  if (!parsed) return null;
  const id = hexIdFor(parsed.row, parsed.col);
  const minDay = minDayForLookback(days, nowMs);
  if (minDay == null) {
    const row = await db
      .prepare(
        `SELECT hex_id, row, col, scan_count, first_ts, last_ts, best_snr, best_rssi,
          last_snr, last_rssi, last_altitude, last_lat, last_lng, last_node_id, last_node_name, nodes_json
         FROM hex_detail WHERE hex_id = ?`
      )
      .bind(id)
      .first<HexDetailRow>();
    return row ? rowToFields(row) : null;
  }
  const result = await db
    .prepare(
      `SELECT hex_id, row, col, scan_count, first_ts, last_ts, best_snr, best_rssi,
        last_snr, last_rssi, last_altitude, last_lat, last_lng, last_node_id, last_node_name, nodes_json
       FROM hex_detail_day WHERE hex_id = ? AND day >= ?`
    )
    .bind(id, minDay)
    .all<HexDetailRow>();
  const merged = mergeDayRows((result.results || []) as HexDetailRow[]);
  return merged[0] ?? null;
}

export async function loadHexesForWindow(
  db: D1Like,
  args: {
    days: number;
    nowMs: number;
    includeNodes?: boolean;
    bounds?: { south: number; north: number; west: number; east: number };
  }
): Promise<HexDetailFields[]> {
  const minDay = minDayForLookback(args.days, args.nowMs);
  const allDays = minDay == null;
  const includeNodes = args.includeNodes !== false;
  if (allDays) {
    let sql = worldSelectSql(true);
    const binds: unknown[] = [];
    if (args.bounds) {
      const b = boundsToRowCol(args.bounds);
      sql = viewportSelectSql(true);
      binds.push(b.rowMin, b.rowMax, b.colMin, b.colMax);
    }
    const result = await db.prepare(sql).bind(...binds).all<HexDetailRow>();
    return ((result.results || []) as HexDetailRow[]).map(rowToFields);
  }

  let sql = worldSelectSql(false);
  const binds: unknown[] = [minDay];
  if (args.bounds) {
    const b = boundsToRowCol(args.bounds);
    sql = viewportSelectSql(false);
    binds.push(b.rowMin, b.rowMax, b.colMin, b.colMax);
  }
  const agg = await db.prepare(sql).bind(...binds).all<{
    hex_id: string;
    row: number;
    col: number;
    scan_count: number;
    first_ts: number;
    last_ts: number;
    best_snr: number | null;
    best_rssi: number | null;
  }>();
  const groups = agg.results || [];
  if (groups.length === 0) return [];
  if (!includeNodes) {
    return groups.map((g) => ({
      hex_id: String(g.hex_id),
      row: Number(g.row),
      col: Number(g.col),
      scan_count: Number(g.scan_count) || 0,
      first_ts: Number(g.first_ts) || 0,
      last_ts: Number(g.last_ts) || 0,
      best_snr: g.best_snr == null ? null : Number(g.best_snr),
      best_rssi: g.best_rssi == null ? null : Number(g.best_rssi),
      last_snr: null,
      last_rssi: null,
      last_altitude: null,
      last_lat: 0,
      last_lng: 0,
      last_node_id: null,
      last_node_name: null,
      nodes: [],
    }));
  }
  const ids = groups.map((g) => String(g.hex_id));
  const merged = new Map<string, HexDetailFields>();
  const chunkSize = 80;
  for (let i = 0; i < ids.length; i += chunkSize) {
    const chunk = ids.slice(i, i + chunkSize);
    const expanded = expandDayRowSql(chunk);
    const dayRows = await db
      .prepare(expanded.sql)
      .bind(minDay, ...expanded.binds)
      .all<HexDetailRow>();
    for (const fields of mergeDayRows((dayRows.results || []) as HexDetailRow[])) {
      merged.set(fields.hex_id, fields);
    }
  }
  return ids.map((id) => merged.get(id)).filter((row): row is HexDetailFields => !!row);
}
