# Mesh Utility Worker

Cloudflare Worker for ingesting scan data, batching writes, and committing scan files to GitHub.

The live app calls it at `https://mesh-utility.org/api`. A single leading `/api` is stripped, so `/api/coverage` is the same handler as `/coverage`. `workers.dev` stays enabled alongside the zone routes.

Pushing to `main` deploys this Worker and the Flutter Pages site (`.github/workflows/deploy.yml`). Publishing a GitHub release builds app artifacts only (`.github/workflows/release-artifacts.yml`); it does not deploy the Worker.

## What It Does
- Accepts scan batches from the client (`POST /scans`)
- Stores scans in D1 immediately
- Batches commits to GitHub (20 scans or 5 minutes)
- Appends committed rows into a single master CSV file (`scans.csv`)
- Serves scan history (`/history`, `/history/:day.ndjson`)
- Serves static-compatible aliases (`/history/index.json`, `/coverage.json`)
- Serves pre-aggregated coverage zones for fast map rendering (`/coverage`)
- Supports signed radio-owned deletion (`POST /delete/challenge`, `POST /delete/:radioId`)

## Setup

### 1. Install and authenticate

```bash
cd worker
npm install
npx wrangler login
cp wrangler.toml.example wrangler.toml
```

### 2. Create and initialize D1

```bash
npm run db:create
npm run db:init
```

Update `wrangler.toml` with the returned `database_id`.

### 3. Configure GitHub token

Create a fine-grained token with repository `contents:write`, then:

```bash
npm run secret:github
```

### 4. Configure worker vars

In `wrangler.toml`:

```toml
[vars]
GITHUB_REPO = "just-stuff-tm/mesh-data"
GITHUB_BRANCH = "main"
ALLOWED_ORIGINS = "https://mesh-utility.org,https://www.mesh-utility.org,https://mesh-utility-tracker.pages.dev,https://*.mesh-utility-tracker.pages.dev,http://localhost:8080,http://localhost:5173,http://localhost:4173"
```

Keep `workers_dev = true` if you add custom zone routes. Wrangler disables `workers.dev` when routes exist unless that flag is set. See `wrangler.toml.example`. Do not commit `GITHUB_TOKEN` or a production `database_id` into docs.

### 5. Run locally or deploy

```bash
npm run dev
npm run check
npm run deploy
```

## API

### `POST /scans`
Accepts an array of scan payloads.

Response example:

```json
{
  "success": true,
  "queued": 5,
  "message": "1 scans queued, 5 total pending"
}
```

### `GET /history`
Returns available scan days.

Example response:

```json
["2026-02-15", "2026-02-14"]
```

### `GET /history/index.json`
Static-compatible alias for `GET /history`.

### `GET /history/:day.ndjson`
Returns newline-delimited scan rows for a day (`YYYY-MM-DD`).

A dead zone is a scan with no response (`nodes` empty, or no node entry with a numeric RSSI). A weak hearing is not a dead zone.

- Optional query params:
  - `lat`, `lng`, and `radiusMiles` together limit rows to a box around that point. Omit any one of them and the filter is not applied.
  - `deadzoneDays`:
    - `1..365` = include dead-zone rows only if the requested day is within the most recent N available scan days
    - `0` (default) = include dead-zone rows for any requested day
  - `pageSize`:
    - `1..1000` = maximum rows per response page (default `1000`)
  - `cursorTimestamp` + `cursorId`:
    - keyset pagination cursor from previous response headers

Pagination response headers:
- `X-Has-More`: `1` when another page exists
- `X-Next-Cursor-Timestamp`: timestamp for next page cursor
- `X-Next-Cursor-Id`: row id for next page cursor

### `GET /coverage?days=7`
Returns aggregated hex coverage zones from D1 for fast map rendering.

`isDeadZone` is true only when that cell has no response. Rows that include a numeric RSSI are not dead zones.

- `days`:
  - `1..365` = most recent N days (default `7` when omitted)
  - `0` = up to the 90 most recent days (`COVERAGE_MAX_DAYS`), not unbounded history
- `deadzoneDays` (optional, defaults to `days`):
  - `1..365` = dead-zone rows are included from the most recent N available scan days
  - `0` = same 90-day cap as `days=0`
- `lat`, `lng`, and `radiusMiles` together limit the aggregate to a box around that point.

### `GET /coverage.json?days=7`
Static-compatible alias for `GET /coverage`.

### `POST /delete/challenge`
Returns a short-lived challenge string for signed ownership verification.

Request body:
```json
{ "radioId": "BFD65811", "publicKey": "..." }
```

### `POST /delete/:radioId`
Deletes scans for a radio after verifying a radio-generated Ed25519 signature.

Request body:
```json
{
  "publicKey": "...",
  "challenge": "mesh-delete-v1:...",
  "signature": "..."
}
```

### `GET /health`
Health check.

## What gets stored

The Worker stores coverage scans: radio id, time, location, and heard nodes (id, RSSI, SNR, and a name when the client sent one).

The Flutter client sends saved contact names only for repeaters and room servers. It does not upload the full contacts list, companion destinations, or channel message text. Those stay on the device (Android and Linux). Do not add sample contact names or message text to this repo.

## Batching Behavior
- Batch size trigger: 20 scans
- Time trigger: 5 minutes
- Commit output: append-only updates to `scans.csv` for successful node detections only
- Dead-zone scans (no response) are persisted in D1 and served via `/history`, but are not written to GitHub CSV
- CSV columns:
  `row_id,radioId,timestamp,datetime_utc,latitude,longitude,altitude,nodeId,rssi,snr,observerName,nodeName,snr_repeater_to_observer,snr_observer_to_repeater`

## Useful Commands

```bash
# pending scans
wrangler d1 execute mesh-utility-db --command "SELECT COUNT(*) FROM scans WHERE committed = 0"

# recent commits table rows
wrangler d1 execute mesh-utility-db --command "SELECT * FROM commits ORDER BY committedAt DESC LIMIT 10"
```

## Environment Variables

| Variable | Description |
|---|---|
| `GITHUB_TOKEN` | GitHub fine-grained token (secret) |
| `GITHUB_REPO` | Target repository (`owner/repo`) |
| `GITHUB_BRANCH` | Target branch |
| `ALLOWED_ORIGINS` | Comma-separated allowed origins |

## License
MIT
