# Mesh Utility Alpha-18

Alpha-18 is the current release.

- GitHub release tag: `Alpha-18` (a full release, not a prerelease)
- App version: `1.0.0-alpha.18+18`
- Side nav footer: **Mesh Utility Alpha-18**, from the installed app version

## Downloads

- Android APK: `mesh-utility-Alpha-18-android.apk`
- Linux: `mesh-utility-Alpha-18-linux-x64.tar.gz`
- Web: https://mesh-utility.org
- Windows: not currently available
- Checksums: `SHA256SUMS.txt` on the release

Android packages since Alpha-12 use a stable signing key. An install older than Alpha-12 needs a one-time uninstall before this package will install over it.

[Add to Obtainium](obtainium://add/https://github.com/mesh-utility/mesh-utility) using source https://github.com/mesh-utility/mesh-utility.

## Current behavior

- **App updates (Android and Linux).** Settings → App updates → Check for updates. Android downloads the APK, verifies the checksum, and opens the installer. Linux **Install update** downloads the tar.gz, verifies the checksum, swaps the install while keeping a `.bak`, and restarts.
- **Contacts (Android and Linux).** Searchable per-radio list stored on the device, including companions. The on-device book can be larger than the radio's book. Large BLE sync resumes and shows **Contacts n/total**.
- **Privacy.** Repeater and room-server names may be uploaded with coverage scans for the public map. The full contacts list stays on the device. Companion destinations are not exposed. Channel message text is never published.
- **Dead Zone** means no response at that location. A weak hearing is not a dead zone.
- **Map tiles** are OpenStreetMap. Dark mode renders those OSM tiles dark. The map does not use Carto.

Earlier notes: [Alpha 8](./alpha-8.md), [Alpha 7](./alpha-7.md), [Alpha 6](./alpha-6.md), [Alpha 5](./alpha-5.md).
