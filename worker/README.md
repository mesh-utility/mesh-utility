# Mesh Utility Worker

Cloudflare Worker for ingesting scan data, batching writes, and committing scan files to GitHub.

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
GITHUB_REPO = "owner/mesh-data"
GITHUB_BRANCH = "main"
ALLOWED_ORIGINS = "https://mesh-utility.org,https://mesh-utility-tracker.pages.dev,https://production.mesh-utility-tracker.pages.dev,http://localhost:5173"
```

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

- Optional query params:
  - `deadzoneDays`:
    - `1..365` = include dead-zone rows only if the requested day is within the most recent N available scan days
    - `0` (default) = include dead-zone rows for any requested day
  - `pageSize`:
    - `1..5000` = maximum rows per response page (default `2000`)
  - `cursorTimestamp` + `cursorId`:
    - keyset pagination cursor from previous response headers

Pagination response headers:
- `X-Has-More`: `1` when another page exists
- `X-Next-Cursor-Timestamp`: timestamp for next page cursor
- `X-Next-Cursor-Id`: row id for next page cursor

### `GET /coverage?days=7`
Returns aggregated hex coverage zones from D1 for fast map rendering.

- `days`:
  - `1..365` = most recent N days
  - `0` = all available days
- `deadzoneDays` (optional, defaults to `days`):
  - `1..365` = dead-zone rows are included from the most recent N available scan days
  - `0` = include dead-zone rows from all available days

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

## Batching Behavior
- Batch size trigger: 20 scans
- Time trigger: 5 minutes
- Commit output: append-only updates to `scans.csv` for successful node detections only
- Dead-zone scans (`nodes: []`) are persisted in D1 and served via `/history`, but are not written to GitHub CSV
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
