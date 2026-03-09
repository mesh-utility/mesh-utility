# Mesh Utility (Flutter)

[![Obtainium](https://img.shields.io/badge/Obtainium-Compatible-3DDC84?logo=android&logoColor=white)](https://obtainium.imranr.dev/)

Native Flutter client for Mesh Utility with BLE radio scanning, local cache, and Cloudflare Worker sync.

## Supported Targets

- [ ] Android
- [ ] iOS
- [ ] Linux
- [ ] macOS
- [ ] Windows
- [ ] Web

## How The App Works

- Connect to a radio over BLE from **Settings → Connections**.
- Start map scanning with the scan control on the map overlay.
- App sends node-discover frames, collects responses, and stores scans locally with location data.
- Smart-scan skips recently covered zones and resumes scanning when moving into stale/unscanned/dead zones.
- Local scans are uploaded/synced with the worker on **Sync now** and on a periodic interval.
- Periodic sync interval is user-configurable from **30 minutes to 24 hours** and is anchored to server/internet time.

## Settings (Current Behavior)

- `Scan Interval`: auto-scan cadence.
- `Smart Scan` + freshness days: skip recent-coverage zones.
- `Cloud History`: worker history window.
- `Deadzone Retrieval`: deadzone fetch window.
- `Update radio position`: for radios without GPS, sets observer radio coordinates to current OS location so mesh peers can see position; this only updates radio coordinates.
- `Offline map tiles`: cache viewed tiles + download/clear local tile cache around current location.
- `Units`: imperial/metric.
- `Stats Radius`: bottom stats filter radius (`0` = all visible data).
- `Upload Interval`: periodic worker sync interval (`30..1440` minutes).
- `Online/Offline Mode`: force offline disables worker sync/upload.
- `Delete radio data`: signed delete flow for connected radio.

## Run Locally

```bash
cd /home/chris/Projects/mesh-utility
flutter pub get
flutter run
```

## Worker (Cloudflare)

```bash
cd /home/chris/Projects/mesh-utility/worker
npx wrangler deploy
```

## Web Build Prep (Cloudflare Pages, No Deploy)

```bash
cd /home/chris/Projects/mesh-utility
WORKER_URL="https://mesh-utility-worker.aaffiliate796.workers.dev" ./tool/build_web_cloudflare.sh
python3 -m http.server 8080 --directory build/web
```

Notes:
- Worker URL can be set with `--dart-define=WORKER_URL=...`.
- SPA routing files are in `web/_redirects`.
- Cache headers are in `web/_headers`.

## Contributing Docs

- Contribution guide: [CONTRIBUTING.md](./CONTRIBUTING.md)
- Agent/developer guardrails: [AGENTS.md](./AGENTS.md)
- CI/CD setup and secrets handling: [docs/ci-cd.md](./docs/ci-cd.md)
- Flutter engineering practices: [docs/flutter-best-practices.md](./docs/flutter-best-practices.md)
