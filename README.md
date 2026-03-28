# Mesh Utility (Flutter)

[![Obtainium](https://img.shields.io/badge/Obtainium-Compatible-3DDC84?logo=android&logoColor=white)](https://obtainium.imranr.dev/) [![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/Just_Stuff_TM)

Native Flutter client for Mesh Utility with BLE radio scanning, local cache, and Cloudflare Worker sync.

## Live Web App

- https://mesh-utility.org/

## Release Notes

- [Alpha 6](./docs/releases/alpha-6.md) (latest)
- [Alpha 5](./docs/releases/alpha-5.md)

## Supported Targets

- [x] Android
- [ ] iOS
- [x] Linux
- [ ] macOS
- [ ] Windows
- [x] Web

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

## Linux Installer (Latest Release)

Downloads the latest release, verifies the checksum, and installs to `~/.local`:

```bash
curl -fsSL https://raw.githubusercontent.com/mesh-utility/mesh-utility/main/tool/install_linux.sh -o install_mesh_utility.sh
chmod +x install_mesh_utility.sh
./install_mesh_utility.sh
```

To install a specific release:

```bash
./install_mesh_utility.sh Alpha-6
```


## Coverage Hex Grid

Coverage zones are keyed to a flat-top hexagonal grid anchored at the geographic origin **(lat 0, lng 0)**. Every GPS fix is snapped to the nearest hex cell centre before being stored or displayed.

Key constants (see [lib/src/services/grid.dart](lib/src/services/grid.dart)):

| Constant | Value | Meaning |
|---|---|---|
| `hexSize` | `0.0007°` | Hex radius in degrees (~78 m at equator) |
| `rowSpacing` | `hexSize × 1.5` | Latitude distance between row centres |
| `colSpacing` | `hexSize × √3 × 1.2` | Longitude distance between column centres |

The grid origin is `(snapLat=0, snapLng=0)`. Every cell is identified by a **hex key** — a `"lat:lng"` string of the snapped centre coordinates (6 decimal places). Example: `"37.771550:-122.419000"`.

To find which hex cell a position belongs to:

```dart
import 'package:mesh_utility/src/services/grid.dart';

final key = hexKey(latitude, longitude); // e.g. "37.771550:-122.419000"
```

Dead zones (no node heard) and live zones both use this key as their unique ID, so querying `coverageZones.firstWhere((z) => z.id == hexKey(lat, lng))` tells you everything known about that cell.

## Contributing Docs

- Contribution guide: [CONTRIBUTING.md](./CONTRIBUTING.md)
- Agent/developer guardrails: [AGENTS.md](./AGENTS.md)
- CI/CD setup and secrets handling: [docs/ci-cd.md](./docs/ci-cd.md)
- Flutter engineering practices: [docs/flutter-best-practices.md](./docs/flutter-best-practices.md)
