/**
 * Scan Batcher - Durable Object for batching scan uploads
 * Accumulates scans and commits them to GitHub in batches to reduce API calls
 */

import { batchCommitToGitHub, getGitHubFileContent } from './github';

interface ScanPayload {
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

const MASTER_CSV_PATH = 'scans.csv';
const HEX_SIZE = 0.0007;
const LNG_SCALE = 1.2;
const ROW_SPACING = HEX_SIZE * 1.5;
const COL_SPACING = HEX_SIZE * Math.sqrt(3) * LNG_SCALE;
const MASTER_CSV_HEADERS = [
  'row_id',
  'radioId',
  'timestamp',
  'datetime_utc',
  'latitude',
  'longitude',
  'altitude',
  'nodeId',
  'rssi',
  'snr',
  'observerName',
  'nodeName',
  'snr_repeater_to_observer',
  'snr_observer_to_repeater',
];
const MAX_MASTER_CSV_BYTES = 95 * 1024 * 1024;
type StoredNode = {
  nodeId?: string;
  name?: string;
  observerName?: string;
  [key: string]: unknown;
};

export class ScanBatcher {
  private state: DurableObjectState;
  private env: { DB?: D1Database };
  private scans: ScanPayload[] = [];
  private batchSize = 20; // Commit every 20 scans
  private batchTimeout = 5 * 60 * 1000; // Or every 5 minutes
  private timeoutId: ReturnType<typeof setTimeout> | null = null;

  constructor(state: DurableObjectState, env: { DB?: D1Database }) {
    this.state = state;
    this.env = env;
    this.init();
  }

  async init() {
    // Load pending scans from storage
    const stored = await this.state.storage.get<ScanPayload[]>('pending_scans');
    if (stored) {
      this.scans = stored;
    }
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname.startsWith('/delete/') && request.method === 'POST') {
      const radioId = (url.pathname.split('/')[2] || '').trim().toUpperCase();
      if (!radioId) {
        return new Response(
          JSON.stringify({ success: false, error: 'radioId required' }),
          { status: 400, headers: { 'Content-Type': 'application/json' } }
        );
      }

      const before = this.scans.length;
      this.scans = this.scans.filter((scan) => (scan.radioId || '').toUpperCase() !== radioId);
      const removed = before - this.scans.length;

      await this.state.storage.put('pending_scans', this.scans);

      return new Response(
        JSON.stringify({ success: true, removed, pending: this.scans.length }),
        { headers: { 'Content-Type': 'application/json' } }
      );
    }

    if (url.pathname === '/flush' && request.method === 'POST') {
      // Force commit current batch
      await this.commitBatch(request.headers);
      return new Response(
        JSON.stringify({ success: true, message: 'Batch committed' }),
        { headers: { 'Content-Type': 'application/json' } }
      );
    }

    if (request.method === 'POST') {
      const newScans: ScanPayload[] = await request.json();
      
      // Store in D1 database immediately
      const db = this.env.DB;
      if (db) {
        try {
          for (const scan of newScans) {
            if (scan.nodes.length > 0) {
              await this.deleteDeadZonesForHex(scan.location.lat, scan.location.lon);
            }

            const normalizedRadioId = this.normalizeRadioId(scan.radioId);

            await db.prepare(`
              INSERT INTO scans (radioId, timestamp, latitude, longitude, altitude, nodes, committed)
              VALUES (?, ?, ?, ?, ?, ?, 0)
            `)
              .bind(
                normalizedRadioId,
                scan.timestamp,
                scan.location.lat,
                scan.location.lon,
                scan.location.altitude || null,
                JSON.stringify(scan.nodes)
              )
              .run();
          }

          await this.backfillNodeNamesInD1(db, newScans);
          await this.backfillRadioMetadataInD1(db, newScans);
        } catch (error) {
          console.error('Failed to store scans in D1:', error);
          // Continue with batching even if D1 storage fails
        }
      }
      
      // Add to batch
      this.scans.push(...newScans);

      // Save to storage
      await this.state.storage.put('pending_scans', this.scans);

      // Check if we should commit
      if (this.scans.length >= this.batchSize) {
        await this.commitBatch(request.headers);
      } else {
        // Set timeout for batch commit
        this.scheduleCommit(request.headers);
      }

      return new Response(
        JSON.stringify({
          success: true,
          queued: this.scans.length,
          message: `${newScans.length} scans queued, ${this.scans.length} total pending`,
        }),
        { headers: { 'Content-Type': 'application/json' } }
      );
    }

    if (url.pathname === '/status') {
      return new Response(
        JSON.stringify({
          pending: this.scans.length,
          batchSize: this.batchSize,
        }),
        { headers: { 'Content-Type': 'application/json' } }
      );
    }

    return new Response('Not Found', { status: 404 });
  }

  private scheduleCommit(headers: Headers) {
    if (this.timeoutId !== null) {
      return; // Already scheduled
    }

    this.timeoutId = setTimeout(async () => {
      await this.commitBatch(headers);
      this.timeoutId = null;
    }, this.batchTimeout);
  }

  private async commitBatch(headers: Headers) {
    if (this.scans.length === 0) {
      return;
    }

    const githubToken = headers.get('X-GitHub-Token');
    const githubRepo = headers.get('X-GitHub-Repo');
    const githubBranch = headers.get('X-GitHub-Branch') || 'main';

    if (!githubToken || !githubRepo) {
      console.error('Missing GitHub credentials');
      return;
    }

    try {
      const env = {
        GITHUB_TOKEN: githubToken,
        GITHUB_REPO: githubRepo,
        GITHUB_BRANCH: githubBranch,
      };

      const scansToCommit = [...this.scans].sort((a, b) => a.timestamp - b.timestamp);
      const uniqueRadios = new Set(scansToCommit.map((scan) => scan.radioId)).size;
      let rowsAppended = 0;

      const maxAttempts = 3;

      for (let attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          const existingCsv = await getGitHubFileContent(env, MASTER_CSV_PATH);
          const updatedCsv = this.buildUpdatedMasterCsv(existingCsv, scansToCommit);
          rowsAppended = updatedCsv.rowsAdded;
          const csvSizeBytes = new TextEncoder().encode(updatedCsv.content).length;

          if (csvSizeBytes > MAX_MASTER_CSV_BYTES) {
            throw new Error(
              `${MASTER_CSV_PATH} exceeded ${(MAX_MASTER_CSV_BYTES / (1024 * 1024)).toFixed(0)}MB; rotate to yearly/monthly CSV before appending more rows`
            );
          }

          await batchCommitToGitHub(
            env,
            [{ path: MASTER_CSV_PATH, content: updatedCsv.content }],
            `Append ${rowsAppended} rows from ${scansToCommit.length} scans (${uniqueRadios} radios) to ${MASTER_CSV_PATH}`
          );
          break;
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          const shouldRetry = message.includes('Failed to update ref') && attempt < maxAttempts;
          if (!shouldRetry) {
            throw error;
          }
          console.warn(
            `Retrying GitHub commit after branch ref moved (attempt ${attempt}/${maxAttempts})`
          );
        }
      }

      console.log(
        `Successfully committed ${scansToCommit.length} scans to GitHub (${rowsAppended} rows appended to ${MASTER_CSV_PATH})`
      );

      // Mark scans as committed in D1
      const db = this.env.DB;
      if (db) {
        try {
          for (const scan of this.scans) {
            await db.prepare(`
              UPDATE scans SET committed = 1
              WHERE radioId = ? AND timestamp = ?
            `)
              .bind(scan.radioId, scan.timestamp)
              .run();
          }

          // Log commit to commits table
          await db.prepare(`
            INSERT INTO commits (commitSha, commitMessage, scanCount)
            VALUES (?, ?, ?)
          `)
            .bind(
              'unknown',
              `Batch commit: ${this.scans.length} scans, ${rowsAppended} rows appended to ${MASTER_CSV_PATH}`,
              this.scans.length
            )
            .run();
        } catch (error) {
          console.error('Failed to update D1 after GitHub commit:', error);
        }
      }

      // Clear batch
      this.scans = [];
      await this.state.storage.delete('pending_scans');

      // Clear timeout
      if (this.timeoutId !== null) {
        clearTimeout(this.timeoutId);
        this.timeoutId = null;
      }
    } catch (error) {
      console.error('Failed to commit batch to GitHub:', error);
      // Keep scans in storage for retry
    }
  }

  /**
   * Build updated CSV content by appending rows to the master CSV.
   * Migrates legacy header format (without row_id) on first write.
   */
  private buildUpdatedMasterCsv(
    existingContent: string | null,
    scans: ScanPayload[]
  ): { content: string; rowsAdded: number } {
    const existingRows = this.normalizeExistingRows(existingContent);
    const nextRowId = existingRows.length + 1;

    const newRows = this.convertToCSVRows(scans, nextRowId);
    const allRows = [...existingRows, ...newRows];

    return {
      content: `${MASTER_CSV_HEADERS.join(',')}\n${allRows.join('\n')}\n`,
      rowsAdded: newRows.length,
    };
  }

  private convertToCSVRows(
    scans: ScanPayload[],
    startRowId: number
  ): string[] {
    const rows: string[] = [];
    let rowId = startRowId;

    for (const scan of scans) {
      const hasDetectedNodes = scan.nodes.length > 0;

      if (!hasDetectedNodes) {
        // Dead-zone scans are kept in D1 only; do not publish to GitHub CSV.
        continue;
      }

      for (const node of scan.nodes) {
        const observerName = node.observerName ?? scan.observerName ?? '';
        const nodeName = node.name ?? '';
        const snrRepeaterToObserver = node.snr;
        const snrObserverToRepeater = node.snrIn ?? '';
        rows.push(
          this.toCsvLine([
            rowId++,
            scan.radioId,
            scan.timestamp,
            new Date(scan.timestamp).toISOString(),
            scan.location.lat.toFixed(6),
            scan.location.lon.toFixed(6),
            scan.location.altitude != null ? scan.location.altitude.toFixed(1) : '',
            node.nodeId,
            node.rssi,
            node.snr,
            observerName,
            nodeName,
            snrRepeaterToObserver,
            snrObserverToRepeater,
          ])
        );
      }
    }

    return rows;
  }

  private normalizeExistingRows(existingContent: string | null): string[] {
    const csv = existingContent ? existingContent.replace(/\r\n/g, '\n').trimEnd() : '';
    if (!csv) {
      return [];
    }

    const lines = csv.split('\n');
    const header = lines[0] ?? '';
    const dataLines = lines.slice(1).filter((line) => line.trim().length > 0);

    const headerText = header.trim();
    const headerColumns = this.parseCsvLine(headerText);
    const headerIndexes = this.resolveHeaderIndexes(headerColumns);
    const rows: string[] = [];

    for (let index = 0; index < dataLines.length; index++) {
      const line = dataLines[index];
      const values = this.parseCsvLine(line);
      const row = this.normalizeCsvRow(values, index + 1, headerIndexes);
      if (row) {
        rows.push(row);
      }
    }

    // Keep only successful scan rows in GitHub CSV (nodeId present).
    // This also cleans up any historical dead-zone rows on the next commit.
    const filtered = rows.filter((line) => {
      const values = this.parseCsvLine(line);
      const nodeId = values[7] ?? '';
      return nodeId.trim().length > 0;
    });

    // Keep row_id dense and stable after dead-zone cleanup.
    return filtered.map((line, index) => {
      const values = this.parseCsvLine(line);
      values[0] = String(index + 1);
      return this.toCsvLine(values.slice(0, MASTER_CSV_HEADERS.length));
    });
  }

  private normalizeCsvRow(
    values: string[],
    legacyRowId: number,
    headerIndexes: ReturnType<ScanBatcher['resolveHeaderIndexes']>
  ): string | null {
    const getValue = (index: number, fallback = ''): string => {
      if (index < 0) return fallback;
      return values[index] ?? fallback;
    };

    const rowId = headerIndexes.rowId >= 0 ? getValue(headerIndexes.rowId, String(legacyRowId)) : String(legacyRowId);
    const radioId = getValue(headerIndexes.radioId);
    const timestamp = getValue(headerIndexes.timestamp);
    const datetimeUtc = getValue(headerIndexes.datetimeUtc);
    const latitude = getValue(headerIndexes.latitude);
    const longitude = getValue(headerIndexes.longitude);
    const altitude = getValue(headerIndexes.altitude);
    const nodeId = getValue(headerIndexes.nodeId);
    const rssi = getValue(headerIndexes.rssi);
    const snr = getValue(headerIndexes.snr);

    if (!radioId || !timestamp || !datetimeUtc || !latitude || !longitude || rssi.length === 0 || snr.length === 0) {
      return null;
    }

    const observerName = getValue(headerIndexes.observerName);
    const nodeName = getValue(headerIndexes.nodeName);
    const snrRepeaterToObserver = getValue(headerIndexes.snrRepeaterToObserver, snr);
    const snrObserverToRepeater = getValue(headerIndexes.snrObserverToRepeater);

    return this.toCsvLine([
      rowId,
      radioId,
      timestamp,
      datetimeUtc,
      latitude,
      longitude,
      altitude,
      nodeId,
      rssi,
      snr,
      observerName,
      nodeName,
      snrRepeaterToObserver,
      snrObserverToRepeater,
    ]);
  }

  private resolveHeaderIndexes(headerColumns: string[]) {
    const idx = (name: string) => headerColumns.indexOf(name);
    const required = {
      radioId: idx('radioId'),
      timestamp: idx('timestamp'),
      datetimeUtc: idx('datetime_utc'),
      latitude: idx('latitude'),
      longitude: idx('longitude'),
      altitude: idx('altitude'),
      nodeId: idx('nodeId'),
      rssi: idx('rssi'),
      snr: idx('snr'),
    };

    for (const [name, index] of Object.entries(required)) {
      if (index === -1) {
        throw new Error(`Unexpected CSV header in ${MASTER_CSV_PATH}: missing "${name}"`);
      }
    }

    return {
      rowId: idx('row_id'),
      radioId: required.radioId,
      timestamp: required.timestamp,
      datetimeUtc: required.datetimeUtc,
      latitude: required.latitude,
      longitude: required.longitude,
      altitude: required.altitude,
      nodeId: required.nodeId,
      rssi: required.rssi,
      snr: required.snr,
      observerName: (() => {
        const observerIdx = idx('observerName');
        if (observerIdx !== -1) return observerIdx;
        const receiverIdx = idx('receiverName');
        return receiverIdx;
      })(),
      nodeName: (() => {
        const nodeNameIdx = idx('nodeName');
        if (nodeNameIdx !== -1) return nodeNameIdx;
        const senderNameIdx = idx('senderName');
        return senderNameIdx;
      })(),
      snrRepeaterToObserver: (() => {
        const explicit = idx('snr_repeater_to_observer');
        return explicit !== -1 ? explicit : required.snr;
      })(),
      snrObserverToRepeater: (() => {
        const explicit = idx('snr_observer_to_repeater');
        if (explicit !== -1) return explicit;
        return idx('snrIn');
      })(),
    };
  }

  private async deleteDeadZonesForHex(lat: number, lon: number): Promise<void> {
    const db = this.env.DB;
    if (!db) return;

    const targetHex = this.hexKey(lat, lon);
    const range = 0.01;
    const result = await db.prepare(`
      SELECT id, latitude, longitude
      FROM scans
      WHERE nodes = '[]'
        AND latitude BETWEEN ? AND ?
        AND longitude BETWEEN ? AND ?
    `)
      .bind(lat - range, lat + range, lon - range, lon + range)
      .all();

    for (const row of result.results as Array<{ id: number; latitude: number; longitude: number }>) {
      if (this.hexKey(row.latitude, row.longitude) !== targetHex) {
        continue;
      }
      await db.prepare(`DELETE FROM scans WHERE id = ?`).bind(row.id).run();
    }
  }

  private snapToHexGrid(lat: number, lon: number): { snapLat: number; snapLon: number } {
    const row = Math.round(lat / ROW_SPACING);
    const isOddRow = Math.abs(row) % 2 === 1;
    const offset = isOddRow ? COL_SPACING / 2 : 0;
    const col = Math.round((lon - offset) / COL_SPACING);
    return {
      snapLat: row * ROW_SPACING,
      snapLon: col * COL_SPACING + offset,
    };
  }

  private hexKey(lat: number, lon: number): string {
    const { snapLat, snapLon } = this.snapToHexGrid(lat, lon);
    return `${snapLat.toFixed(6)}:${snapLon.toFixed(6)}`;
  }

  private parseCsvLine(line: string): string[] {
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

  private toCsvLine(values: Array<string | number>): string {
    return values.map((value) => this.escapeCsvValue(String(value))).join(',');
  }

  private escapeCsvValue(value: string): string {
    const escaped = value.replace(/"/g, '""');
    if (/[",\n\r]/.test(escaped)) {
      return `"${escaped}"`;
    }
    return escaped;
  }

  /**
   * Backfill historical scan rows when we receive a better/current node name.
   * This keeps older D1 records consistent for history views.
   */
  private async backfillNodeNamesInD1(db: D1Database, scans: ScanPayload[]): Promise<void> {
    const nameUpdates = new Map<string, string>();

    for (const scan of scans) {
      for (const node of scan.nodes) {
        const nodeId = this.normalizeHexId(node.nodeId);
        const name = typeof node.name === 'string' ? node.name.trim() : '';
        if (!nodeId || !name) {
          continue;
        }
        if (name.startsWith('Unknown (')) {
          continue;
        }
        nameUpdates.set(nodeId, name);
      }
    }

    if (nameUpdates.size === 0) {
      return;
    }

    for (const [nodeId, latestName] of nameUpdates.entries()) {
      const prefix8 = nodeId.length >= 8 ? nodeId.slice(0, 8) : nodeId;
      const likeNodeId = this.escapeLikePattern(prefix8);
      const rows = await db.prepare(
        `
          SELECT id, nodes
          FROM scans
          WHERE nodes LIKE ? ESCAPE '\\'
        `
      )
        .bind(`%"nodeId":"${likeNodeId}%`)
        .all();

      for (const row of rows.results as Array<{ id: number; nodes: string }>) {
        let parsedNodes: StoredNode[];
        try {
          const parsed = JSON.parse(row.nodes);
          if (!Array.isArray(parsed)) {
            continue;
          }
          parsedNodes = parsed;
        } catch {
          continue;
        }

        let changed = false;
        for (const parsedNode of parsedNodes) {
          if (!parsedNode) {
            continue;
          }
          const parsedNodeId = this.normalizeHexId(parsedNode.nodeId);
          if (!this.idsLikelySameDevice(parsedNodeId, nodeId)) {
            continue;
          }
          const existingName =
            typeof parsedNode.name === 'string' ? parsedNode.name.trim() : '';
          const existingIsUnknown = this.isUnknownLike(existingName);
          // Always upgrade unknown/empty names when ID matches a known node.
          if (!existingIsUnknown && existingName === latestName) {
            continue;
          }
          parsedNode.name = latestName;
          changed = true;
        }

        if (!changed) {
          continue;
        }

        await db.prepare(
          `
            UPDATE scans
            SET nodes = ?
            WHERE id = ?
          `
        )
          .bind(JSON.stringify(parsedNodes), row.id)
          .run();
      }
    }
  }

  private async backfillRadioMetadataInD1(db: D1Database, scans: ScanPayload[]): Promise<void> {
    const observerNameUpdates = new Map<string, string>();
    const normalizedRadioIds = new Set<string>();

    for (const scan of scans) {
      const normalizedRadioId = this.normalizeRadioId(scan.radioId);
      if (!normalizedRadioId) {
        continue;
      }

      normalizedRadioIds.add(normalizedRadioId);

      const observerName =
        typeof scan.observerName === 'string' ? scan.observerName.trim() : '';
      if (!observerName || observerName.startsWith('Unknown (')) {
        continue;
      }
      observerNameUpdates.set(normalizedRadioId, observerName);
    }

    if (normalizedRadioIds.size === 0) {
      return;
    }

    // Ensure canonical uppercase radioId across all rows.
    for (const normalizedRadioId of normalizedRadioIds) {
      await db.prepare(
        `
          UPDATE scans
          SET radioId = ?
          WHERE UPPER(radioId) = ?
            AND radioId != ?
        `
      )
        .bind(normalizedRadioId, normalizedRadioId, normalizedRadioId)
        .run();
    }

    if (observerNameUpdates.size === 0) {
      return;
    }

    // Backfill observerName in embedded nodes JSON for history output consistency.
    for (const [radioId, observerName] of observerNameUpdates.entries()) {
      const rows = await db.prepare(
        `
          SELECT id, nodes
          FROM scans
          WHERE radioId = ?
        `
      )
        .bind(radioId)
        .all();

      for (const row of rows.results as Array<{ id: number; nodes: string }>) {
        let parsedNodes: StoredNode[];
        try {
          const parsed = JSON.parse(row.nodes);
          if (!Array.isArray(parsed)) {
            continue;
          }
          parsedNodes = parsed;
        } catch {
          continue;
        }

        let changed = false;
        for (const parsedNode of parsedNodes) {
          if (!parsedNode) {
            continue;
          }
          const existingObserver =
            typeof parsedNode.observerName === 'string'
              ? parsedNode.observerName.trim()
              : '';
          if (existingObserver === observerName) {
            continue;
          }
          parsedNode.observerName = observerName;
          changed = true;
        }

        if (!changed) {
          continue;
        }

        await db.prepare(
          `
            UPDATE scans
            SET nodes = ?
            WHERE id = ?
          `
        )
          .bind(JSON.stringify(parsedNodes), row.id)
          .run();
      }
    }
  }

  private escapeLikePattern(value: string): string {
    return value.replace(/\\/g, '\\\\').replace(/%/g, '\\%').replace(/_/g, '\\_');
  }

  private normalizeHexId(value: unknown): string {
    if (typeof value !== 'string') return '';
    return value.trim().toUpperCase().replace(/[^0-9A-F]/g, '');
  }

  private isUnknownLike(value: string): boolean {
    const v = value.trim();
    if (!v) return true;
    const lower = v.toLowerCase();
    return lower === 'unknown' || lower.startsWith('unknown (');
  }

  private idsLikelySameDevice(a: string, b: string): boolean {
    if (!a || !b) return false;
    if (a === b) return true;
    if (a.startsWith(b) || b.startsWith(a)) return true;
    const a8 = a.length >= 8 ? a.slice(0, 8) : a;
    const b8 = b.length >= 8 ? b.slice(0, 8) : b;
    return a8 === b8;
  }

  private normalizeRadioId(value: unknown): string {
    return typeof value === 'string' ? value.trim().toUpperCase() : '';
  }
}
