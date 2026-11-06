/** Helpers for the scan_days summary table. */

export type ScanDayRow = {
  day: string;
  scan_count?: number;
  min_ts?: number | null;
  max_ts?: number | null;
};

export type RowsReadTracker = { rowsRead: number };

export function trackMeta<T extends { meta?: { rows_read?: number } }>(
  tracker: RowsReadTracker | null | undefined,
  result: T
): T {
  if (tracker && result?.meta?.rows_read != null) {
    tracker.rowsRead += Number(result.meta.rows_read) || 0;
  }
  return result;
}

/** UTC calendar day YYYY-MM-DD for a ms epoch timestamp. */
export function utcDayFromTs(ts: number): string {
  return new Date(ts).toISOString().slice(0, 10);
}

export async function listScanDaysDesc(
  db: D1Database,
  tracker?: RowsReadTracker | null
): Promise<ScanDayRow[]> {
  const result = await db
    .prepare(
      `SELECT day, scan_count, min_ts, max_ts FROM scan_days ORDER BY day DESC`
    )
    .all();
  trackMeta(tracker, result as { meta?: { rows_read?: number } });
  return (result.results || []) as ScanDayRow[];
}

export async function upsertScanDay(
  db: D1Database,
  day: string,
  ts: number
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO scan_days (day, scan_count, min_ts, max_ts)
       VALUES (?, 1, ?, ?)
       ON CONFLICT(day) DO UPDATE SET
         scan_count = scan_days.scan_count + 1,
         min_ts = CASE
           WHEN scan_days.min_ts IS NULL OR excluded.min_ts < scan_days.min_ts
           THEN excluded.min_ts ELSE scan_days.min_ts END,
         max_ts = CASE
           WHEN scan_days.max_ts IS NULL OR excluded.max_ts > scan_days.max_ts
           THEN excluded.max_ts ELSE scan_days.max_ts END`
    )
    .bind(day, ts, ts)
    .run();
}

/** Inclusive ms range covering UTC calendar days [oldest..newest] from scan_days rows. */
export function timestampRangeForDays(days: ScanDayRow[]): {
  minTs: number;
  maxTs: number;
} | null {
  if (days.length === 0) return null;
  let minTs = Number.POSITIVE_INFINITY;
  let maxTs = Number.NEGATIVE_INFINITY;
  for (const d of days) {
    if (d.min_ts != null && Number.isFinite(Number(d.min_ts))) {
      minTs = Math.min(minTs, Number(d.min_ts));
    } else {
      minTs = Math.min(minTs, Date.parse(d.day + 'T00:00:00Z'));
    }
    if (d.max_ts != null && Number.isFinite(Number(d.max_ts))) {
      maxTs = Math.max(maxTs, Number(d.max_ts));
    } else {
      // End of UTC day inclusive
      maxTs = Math.max(maxTs, Date.parse(d.day + 'T00:00:00Z') + 86_400_000 - 1);
    }
  }
  if (!Number.isFinite(minTs) || !Number.isFinite(maxTs)) return null;
  return { minTs, maxTs };
}
