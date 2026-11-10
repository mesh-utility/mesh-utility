# Mesh Utility (Flutter)

[![Obtainium](https://img.shields.io/badge/Obtainium-Compatible-3DDC84?logo=android&logoColor=white)](https://obtainium.imranr.dev/) [![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/Just_Stuff_TM)

Flutter client for MeshCore coverage mapping. It scans over BLE, keeps scans on the device, and syncs coverage to a Cloudflare Worker.

**Current release: Alpha-19** (`pubspec.yaml` version `1.0.0-alpha.19+19`).

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
- **Android:** the update downloads the APK, verifies it against `SHA256SUMS.txt`, and opens the system installer. Alpha-17 and Alpha-18 cannot open that installer; install Alpha-19 once from the GitHub release or Obtainium.
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
- Start the scan loop with Play on the map. Force scan (the bolt) works only while that loop is running. The next-scan countdown starts when the discovery request is sent.
- The app sends node-discover frames, collects responses, and stores scans locally with location.
- Smart scan skips recently covered zones and scans again in stale, unscanned, or dead zones. A dead zone is always eligible because it means no response was heard there.
- Local scans upload on **Sync now** and on a periodic interval (30 minutes to 24 hours), anchored to server time.
- **Online / Offline Mode** in Settings pauses worker sync when forced offline. Online mode requires the privacy policy.

## Settings (current behavior)

Settings is grouped into **Radio / Connection**, **Scanning**, **Map & Display**, **Data & Cache**, **App updates**, and **About**.

- **Radio / Connection:** Update radio position (a radio without GPS; writes the current OS location onto the radio only) and Online / Offline Mode.
- **Scanning:** Scan Interval (20–300 seconds) and Smart scan freshness days (1–14).
- **Map & Display:** offline map tiles, Stats Radius (`0` = all visible data), units, and theme. Coverage hexes stay at true size on the fixed grid at every zoom.
- **Data & Cache > Scan cache area:** one control for what is downloaded and kept. Radius around the last location: 10, 25, 50, 100, 250, 500, or 800 miles. States and provinces (any country, with a search box). US counties. Global. Changing it downloads the new area or trims scans that no longer fit. Larger areas use more storage and can slow startup.
- **Cloud History** and **Deadzone Retrieval:** how many days to load. Dead zones are a separate window.
- **Upload Interval:** periodic worker sync (`30`–`1440` minutes), anchored to server time.
- **App updates:** Android and Linux only. See above.
- **Delete My Data:** signed delete for the connected radio.

## Scan history

History opened from a map hex is titled **Cell history** and the list scrolls. With no cell selected the title is **All Scans**. One row is labeled "1 scan".

A radio name ending in **· synced** means that row was recorded by a different radio than the one connected now. Those rows are shared scans, usually from the cloud.

## Web Install tab

The web app has an **Install** tab. It explains the Android APK, the Linux archive, and Obtainium, and it shows what is in the latest GitHub release (Fixes, Enhancements, Other changes). If that request fails, the page shows a saved copy of the notes and a link to the release on GitHub.

## Worker area query

`GET /history/:day.ndjson` and `GET /coverage` accept an area. The worker checks these in order:

1. `minLat`, `maxLat`, `minLng`, `maxLng` — map bounds. When all four are present they win, and `lat` / `lng` / `radiusMiles` are not used for the query. `minLng` greater than `maxLng` crosses the antimeridian.
2. Repeated `division` ids, up to 32. Unknown ids are skipped. If every id is unknown, the response is empty.
3. `lat`, `lng`, and `radiusMiles` together. Radius is still capped at 250 miles.
4. Otherwise the request is worldwide.

A radius above 250 miles is sent with the map bounds as well. A current worker uses the bounds. An older server ignores the bounds and still returns at most 250 miles around the point. The app then keeps only the area you selected. States, provinces, and counties are sent as those bounds (not as `division` ids). When your last location is inside that box, the point sent for older servers is that location, and the radius still reaches the far corner of the box.

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
./install_mesh_utility.sh Alpha-19
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

Publishing a full release runs [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml), which deploys the Cloudflare Worker and the Flutter web app to Cloudflare Pages.

Publishing a GitHub release runs [`.github/workflows/release-artifacts.yml`](.github/workflows/release-artifacts.yml), which builds release artifacts and attaches them to that release.

Details, secrets, and the branch list are in [docs/ci-cd.md](./docs/ci-cd.md).

## Release notes

- [Alpha 19](./docs/releases/alpha-19.md) (current)
- [Alpha 18](./docs/releases/alpha-18.md)
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
