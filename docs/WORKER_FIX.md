# mesh-utility-worker D1 rows-read fix (PREP only)

**Date:** 2026-11-05 (America/New_York)  
**Status:** Local prep complete. **No deploy, no remote D1 writes, no git push.**  
**Grok Build:** Started headless but was interrupted after only reading sources; implementation finished directly in `/workspace/mesh-utility/worker-fix`.

## Repos found

| Org spelling | Result |
|---|---|
| `mesh-utilty` (user spelling) | **404** — does not exist |
| `mesh-utility` | **Exists** (gh PAT blocked by org lifetime policy; public clone + GitHub connector worked) |

| Repo | Role | Default branch | HEAD / last push | Matches live Pages `c6490ef1` (2026-04-12)? |
|---|---|---|---|---|
| **`mesh-utility/mesh-utility`** | **Flutter app + Worker source (`worker/`)** | `main` | `f21c61cf` 2026-04-12 — “Alpha 8…” | **YES — exact commit** |
| `just-stuff-tm/mesh-utility-tracker` | Legacy React/Vite + older `worker/` (Feb 2026) | `mesh-utility` | older | No (Pages now serves Flutter) |
| `just-stuff-tm/mesh-data` | Public `scans.csv` seed | `main` | — | Dataset only |
| `just-stuff-tm/mesh-all` | Dart stub | `main` | — | Not the live app |

Clones (shallow): `/workspace/mesh-utility/flutter-app`, `tracker`, `mesh-data`.  
Working tree for the fix: `/workspace/mesh-utility/worker-fix` (copy of `flutter-app/worker`).  
Live Worker backup: `/workspace/mesh-utility/backup/worker-2026-11-05/` (`index.js` bundled, bindings, `d1_schema.sql`, scans=**147452**, commits=1889).

---

## What changed (worker-fix)

### Schema / migrations
- `migrations/0001_scan_days.sql` — `scan_days(day PK, scan_count, min_ts, max_ts)` + index  
- `migrations/0001_scan_days_rollback.sql`  
- `migrations/0002_backfill_scan_days.sql` — one-time `GROUP BY` backfill  
- `migrations/0002_backfill_scan_days_rollback.sql`  
- `schema.sql` updated for fresh local installs  

### Code
- `src/scan_days.ts` — list/upsert/range helpers + rows_read tracker  
- `src/index.ts` — `/history` reads `scan_days`; `/coverage` uses timestamp range (index-friendly) instead of `date(...) IN (...)`; Cache API + ETag/304; `_debug=1` / `DEBUG_ROWS=1` → `X-D1-Rows-Read`  
- `src/batch.ts` — upsert `scan_days` on each insert  

### Flutter client (local only, in `flutter-app/`)
- `app_config.dart` — default Worker URL → `workers.dev` (was broken `mesh-utility.org/api`)  
- `settings_store.dart` — stop “migrating” working `workers.dev` **to** the broken `/api` URL; migrate **away** from `/api` instead  

### Tooling
- `scripts/seed-local-d1.mjs`, `scripts/bench-endpoints.mjs`  
- Results: `/workspace/mesh-utility/bench-results.json`  

---

## Before / after rows-read

### Local seed (6000 scans, 22 days)

| Endpoint | Before (approx) | After (measured) |
|---|---:|---:|
| `GET /history` | ~**6000** (DISTINCT full scan) | **22** (`scan_days`) |
| `GET /coverage?days=7` | ~6000 DISTINCT + ~3055 scan rows | **3077** (scan_days + timestamp range; no DISTINCT) |
| `GET /coverage?days=0` | bind-storm / **500** when many days | **200**, **6022** rows_read (capped window; all 22 local days) |
| `GET /history/:day.ndjson?pageSize=100` | + optional DISTINCT if `deadzoneDays>0` | **101** (page only; no DISTINCT) |
| ETag revalidate `/coverage?days=7` | n/a | **304** |

### Live projection (prod D1 ~147 452 scans)

| Endpoint | Before (audit 2026-11-05) | After (expected) |
|---|---:|---|
| `GET /history` | **~147 452** rows_read / call | **~#distinct days** (≪ scans) |
| `/history` DISTINCT component of `/coverage` | **~147 452** again | **eliminated** |
| Free D1 5M rows/day | Blown by ~15 history calls alone | History becomes cheap; coverage still proportional to scans in the selected window |

Response shapes unchanged: `/history` → `string[]`; `/coverage` → zones with `id,centerLat,centerLng,radiusMeters,avgRssi,avgSnr,scanCount,lastScanned,isDeadZone,polygon,radioId`.

---

## Bugs found and fixed (prep)

1. **`SELECT DISTINCT date(...) FROM scans` on `/history`, `/coverage`, and `deadzoneDays` path** — full table scan; primary free-tier burner. **Fix:** `scan_days` summary + upsert on insert.  
2. **`/coverage?days=0` → too many SQL variables / 500** — binds one placeholder per day. **Fix:** timestamp range query; cap window at `COVERAGE_MAX_DAYS=90`.  
3. **`date(timestamp/1000,'unixepoch') IN (...)`** — prevents use of `idx_timestamp`. **Fix:** `timestamp >= ? AND <= ?`.  
4. **History day window `T23:59:59Z`** — drops scans with ms in the last second of the UTC day. **Fix:** `dayStart + 86400000 - 1`.  
5. **Flutter `AppConfig` default `https://mesh-utility.org/api`** — Pages returns SPA HTML, not the Worker. **Fix (local):** default to `workers.dev`.  
6. **Flutter `SettingsStore` treated `workers.dev` as “legacy” and migrated users to `deployedWorkerUrl` (`/api`)** — actively broke working clients. **Fix (local):** migrate **off** `mesh-utility.org/api` instead.  

### Behavior-changing / risky (flag for user)

| Change | Risk |
|---|---|
| `days=0` now means “up to 90 most recent days”, not literally all history | Map may omit very old zones unless days raised / cap changed |
| NDJSON `pageSize` max **1000** (was 5000); default 1000 (was 2000) | Clients asking for 2000–5000 get fewer rows/page (still paginated via cursors) |
| Cache API 60–180s on `/history` & `/coverage` | Slightly stale reads after uploads until TTL/ETag miss |
| `scan_days` **not decremented on delete** (radio delete / deadzone cleanup) | Day may remain in `/history` index with stale `scan_count` until backfill; empty days possible. **Recommend follow-up:** recompute day on delete or periodic reconcile. |
| Flutter URL default / migration change | Existing installs with saved `/api` URL get migrated to Worker on next settings load — **desired**, but confirm before shipping app release |

### Not fixed here (call out)

- No zone Worker route: `mesh-utility.org/api/*` still SPA until a route/Pages proxy is added (needs deploy approval).  
- `scan_days` maintenance on DELETE paths.  
- Precomputed coverage snapshots in R2 (P1 from audit) — Cache API only for now.  

---

## Deploy steps (DO NOT RUN until user approves)

1. **Backup already taken:** `/workspace/mesh-utility/backup/worker-2026-11-05/index.js` (+ bindings/settings).  
2. Review diff in `worker-fix/` (and optional Flutter commits in `flutter-app/`).  
3. Copy changes into git clone `flutter-app/worker/` (or open a PR on `mesh-utility/mesh-utility`) — **user must approve commit/push**.  
4. Remote D1 (aaffiliate796 / `mesh-utility-db`):
   ```bash
   wrangler d1 execute mesh-utility-db --remote --file migrations/0001_scan_days.sql
   wrangler d1 execute mesh-utility-db --remote --file migrations/0002_backfill_scan_days.sql
   ```
   Backfill reads all scans once (`GROUP BY`); expect a one-time rows-read spike (~147k+).  
5. Deploy Worker only (not Pages unless Flutter URL fix ships):
   ```bash
   cd worker-fix   # or flutter-app/worker after copy
   wrangler deploy   # account aaffiliate796, script mesh-utility-worker
   ```
6. Smoke: `GET .../history`, `/coverage?days=7`, `/coverage?days=0` (expect 200), check D1 analytics next day.  
7. Optional later: Flutter release with URL fix; Pages proxy `/api/*` → Worker; Bot Fight / rate limit (separate approval).  

## Rollback

1. Redeploy backed-up script:  
   `wrangler deploy` using `/workspace/mesh-utility/backup/worker-2026-11-05/index.js` (or previous Workers version from dashboard).  
2. Optional schema rollback (safe; old code ignores table):  
   `wrangler d1 execute mesh-utility-db --remote --file migrations/0001_scan_days_rollback.sql`  
3. Flutter: revert `app_config.dart` / `settings_store.dart` if an app build was released.  

---

## Local verify commands

```bash
cd /workspace/mesh-utility/worker-fix
SEED_MAX_GROUPS=6000 node scripts/seed-local-d1.mjs
node scripts/bench-endpoints.mjs
# or: npx wrangler dev --local --port 8787
# curl -D- 'http://127.0.0.1:8787/history?_debug=1'
```


---

## Deployed (live)

| Field | Value |
|---|---|
| **When** | 2026-11-05 19:39:09 EST (America/New_York) |
| **Worker version id** | `3aa0796d-2278-470d-ac81-5d573389b485` |
| **Previous deployment** | `b927577b-cad6-4581-9c3c-b36748fd04c1` (2026-04-12); script backup `backup/worker-2026-11-05/index.js` |
| **Account** | aaffiliate796 |
| **PR** | https://github.com/mesh-utility/mesh-utility/pull/2 → merge commit `e935bb461cc01d4bd67ef14f8131e856846fbe0f` |
| **D1 0001** | rows_read 3, rows_written 4 |
| **D1 0002 backfill** | rows_read 294904, rows_written 360 → 120 scan_days |
| **Pages** | Not Git-connected (`source={}`); prod still `c6490ef1` on branch `mesh-utility`. Merge to `main` did not auto-deploy Pages. |

### Live smoke (post-deploy)

| Check | Result |
|---|---|
| `/health` | 200 ok |
| `/history` | 200, 120 days, same set as pre |
| `/history/{day}.ndjson` | 200, shape OK |
| `/coverage?days=7` | 200, 644 zones, keys match |
| ETag 304 | OK |
| `/coverage?days=0` | **200**, 9149 zones (pre **500** too many SQL variables) |

### Rollback (Worker)

```bash
export CLOUDFLARE_API_TOKEN=…   # aaffiliate796
export CLOUDFLARE_ACCOUNT_ID=fd2b7856d928fbd1c7c3c190d16858ad
# Cloudflare Dashboard → Workers → mesh-utility-worker → Deployments → rollback to b927577b…
# Or redeploy backup bundle at /workspace/mesh-utility/backup/worker-2026-11-05/index.js
# Optional drop scan_days:
# npx wrangler d1 execute mesh-utility-db --remote --file worker/migrations/0001_scan_days_rollback.sql
```

Pages rollback: N/A (no Pages deploy). Current prod deployment id: `c6490ef1-39c6-4e5e-9203-e9f2703d336f`.


---

## Zone route `/api/*` (follow-up)

Worker accepts `/api/...` by stripping one `/api` prefix (so `/api/coverage` ≡ `/coverage`).
`worker/wrangler.toml` adds zone routes:

- `mesh-utility.org/api/*`
- `www.mesh-utility.org/api/*`

Deploy workflow keeps `WORKER_URL=https://mesh-utility.org/api`.

### Rollback
- Worker version before this change: `4c934153-8bb5-4d67-86bf-35047dc5f4c4`
- Pages deploy before this change: `4bc62c69-890a-4025-9c9e-4eb317ad9e94`
- Or delete the `/api/*` Worker routes in the zone / revert the PR and redeploy.
