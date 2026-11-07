# Mesh Utility (Flutter)

[![Obtainium](https://img.shields.io/badge/Obtainium-Compatible-3DDC84?logo=android&logoColor=white)](https://obtainium.imranr.dev/) [![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/Just_Stuff_TM)

Flutter client for MeshCore coverage mapping. It scans over BLE, keeps scans on the device, and syncs coverage to a Cloudflare Worker.

**Current release: Alpha-18** (`pubspec.yaml` version `1.0.0-alpha.18+18`).

Releases are full GitHub releases (not prereleases) tagged `Alpha-N`. The app version in pubspec is `1.0.0-alpha.N+N`. The side nav footer reads **Mesh Utility Alpha-N**, taken from the installed app version.

## Downloads

| Platform | Artifact |
|---|---|
| Android | `mesh-utility-Alpha-N-android.apk` on the GitHub release |
| Linux | `mesh-utility-Alpha-N-linux-x64.tar.gz` on the GitHub release |
| Web | https://mesh-utility.org |
| Windows | Not currently available |

Each release also includes `SHA256SUMS.txt`.

Published Android APKs have used a stable signing key since **Alpha-12**. An install older than Alpha-12 must be uninstalled once before Alpha-12 or newer will install. Updates from Alpha-12 onward replace the existing app.

Source: https://github.com/mesh-utility/mesh-utility

## Add to Obtainium

[Add to Obtainium](obtainium://add/https://github.com/mesh-utility/mesh-utility)

Obtainium source: https://github.com/mesh-utility/mesh-utility

Add that repo (or open the link on a device with Obtainium). Obtainium tracks full `Alpha-N` releases and installs the Android APK asset.

## In-app updates

On Android and Linux, open **Settings → App updates**.

- **Check for updates** looks up the latest full GitHub release. On startup the app checks again when the last check was at least 12 hours ago.
- **Android:** the update downloads the APK, verifies it against `SHA256SUMS.txt`, and opens the system installer.
- **Linux:** **Install update** downloads the `tar.gz`, verifies the checksum, swaps the install directory while keeping the previous tree as a `.bak`, and restarts the app.

Web, Windows, iOS, and macOS do not offer this updater.

## Contacts

On Android and Linux, **Contacts** in the side nav is a searchable list (name or id) for the connected radio.

- The book is stored on the device, one book per radio. The app keeps contacts after the radio itself has dropped them, including companions it has heard.
- A full BLE contact sync of a large book resumes from the newest saved `lastmod` and shows progress as **Contacts n/total** while the radio reports the book size.

Web and other platforms do not keep this on-device book.

## Privacy

Online mode uploads coverage scans to the Worker, which stores them in D1 for the public map. Successful detections are also appended to the public `scans.csv`.

- Saved contact names are included on those scans only for repeaters and room servers.
- The full contacts list stays on the device. Companion destinations are not exposed. Companion and other non-infrastructure contact names are left off the upload.
- Channel message text is never published.

A name that arrived on a radio advert, and that is not a saved companion contact, can still be stored with that scan. An observer label on a scan is not a companion destination.

## Map

The map uses [OpenStreetMap](https://www.openstreetmap.org/copyright) tiles (`tile.openstreetmap.org`) for the Standard and Dark layers. Dark mode is those same OSM tiles rendered dark. The app does not use Carto tiles. The Satellite layer is Esri World Imagery.

A **Dead Zone** is a location with no response. A weak or noisy hearing is not a dead zone.

## Supported targets

- [x] Android
- [ ] iOS
- [x] Linux
- [ ] macOS
- [ ] Windows (build not currently available)
- [x] Web

## How the app works

- Connect a radio over BLE from **Connections** in the side nav.
- Start map scanning with the scan control on the map overlay.
- The app sends node-discover frames, collects responses, and stores scans locally with location.
- Smart scan skips recently covered zones and scans again in stale, unscanned, or dead zones. A dead zone is always eligible because it means no response was heard there.
- Local scans upload on **Sync now** and on a periodic interval (30 minutes to 24 hours), anchored to server time.
- **Online / Offline Mode** in Settings pauses worker sync when forced offline. Online mode requires the privacy policy.

## Settings (current behavior)

- **Scan Interval:** auto-scan cadence (20–300 seconds).
- **Smart scan** and freshness days (1–14): skip zones covered inside that window.
- **Update radio position:** for a radio without GPS, write the current OS location onto the radio so peers can see it. This only updates radio coordinates.
- **Offline map tiles:** cache viewed tiles, and download or clear a local tile cache around the current location.
- **Units:** imperial or metric.
- **Stats Radius:** bottom stats filter (`0` = all visible data).
- **Cloud History:** how many days of worker history to load.
- **Deadzone Retrieval:** how far back to fetch dead-zone rows, separate from successful history.
- **Sync Download Scope:** global, or a radius around the current location.
- **Upload Interval:** periodic worker sync (`30`–`1440` minutes).
- **App updates:** Android and Linux only. See above.
- **Delete My Data:** signed delete for the connected radio.

## Run locally

```bash
flutter pub get
flutter run
```

Worker (see [worker/README.md](./worker/README.md)):

```bash
cd worker
npm ci
npm run check
```

## Linux installer

Downloads a release, verifies the checksum, and installs under `~/.local`:

```bash
curl -fsSL https://raw.githubusercontent.com/mesh-utility/mesh-utility/main/tool/install_linux.sh -o install_mesh_utility.sh
chmod +x install_mesh_utility.sh
./install_mesh_utility.sh
```

To install a specific release:

```bash
./install_mesh_utility.sh Alpha-18
```

## Coverage hex grid

Coverage zones use a flat-top hexagonal grid anchored at **(lat 0, lng 0)**. Each GPS fix is snapped to the nearest hex center before it is stored or drawn.

Constants in [lib/src/services/grid.dart](lib/src/services/grid.dart):

| Constant | Value | Meaning |
|---|---|---|
| `hexSize` | `0.0007°` | Hex radius in degrees (~78 m at the equator) |
| `rowSpacing` | `hexSize × 1.5` | Latitude distance between row centers |
| `colSpacing` | `hexSize × √3 × 1.2` | Longitude distance between column centers |

The cell id is a hex key: snapped `"lat:lng"` at 6 decimal places, for example `"37.771550:-122.419000"`.

```dart
import 'package:mesh_utility/src/services/grid.dart';

final key = hexKey(latitude, longitude);
```

Dead zones and live zones share that key. A zone is a dead zone when that cell has no response.

## Deploy

Pushing to `main` runs [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml), which deploys the Cloudflare Worker and the Flutter web app to Cloudflare Pages.

Publishing a GitHub release runs [`.github/workflows/release-artifacts.yml`](.github/workflows/release-artifacts.yml), which builds release artifacts and attaches them to that release.

Details, secrets, and the branch list are in [docs/ci-cd.md](./docs/ci-cd.md).

## Release notes

- [Alpha 18](./docs/releases/alpha-18.md) (current)
- [Alpha 8](./docs/releases/alpha-8.md)
- [Alpha 7](./docs/releases/alpha-7.md)
- [Alpha 6](./docs/releases/alpha-6.md)
- [Alpha 5](./docs/releases/alpha-5.md)

## Contributing

- [CONTRIBUTING.md](./CONTRIBUTING.md)
- [AGENTS.md](./AGENTS.md)
- [docs/ci-cd.md](./docs/ci-cd.md)
- [docs/flutter-best-practices.md](./docs/flutter-best-practices.md)
- [worker/README.md](./worker/README.md)
