# Mesh Utility Alpha-19

Alpha-19 is the current release.

- GitHub release tag: `Alpha-19` (a full release, not a prerelease)
- App version: `1.0.0-alpha.19+19`
- Side nav footer: **Mesh Utility Alpha-19**, from the installed app version

## Downloads

- Android APK: `mesh-utility-Alpha-19-android.apk`
- Linux: `mesh-utility-Alpha-19-linux-x64.tar.gz`
- Web: https://mesh-utility.org
- Windows: not currently available
- Checksums: `SHA256SUMS.txt` on the release

Android packages since Alpha-12 use a stable signing key. An install older than Alpha-12 needs a one-time uninstall before this package will install over it.

[Add to Obtainium](obtainium://add/https://github.com/mesh-utility/mesh-utility) using source https://github.com/mesh-utility/mesh-utility.

## Fixes

Android in-app update failed after the APK downloaded and the checksum matched. The system installer could not find a FileProvider for `org.meshutility.app.fileprovider`. This release declares that provider, so the installer can open.

If Mesh Utility is not allowed to install unknown apps, the update opens that system setting and asks you to allow it, then try again.

Alpha-17 and Alpha-18 cannot launch the installer. Install Alpha-19 once manually from the GitHub release, or with Obtainium. After Alpha-19 is installed, later updates can install from inside the app.

Earlier notes: [Alpha 18](./alpha-18.md), [Alpha 8](./alpha-8.md), [Alpha 7](./alpha-7.md), [Alpha 6](./alpha-6.md), [Alpha 5](./alpha-5.md).
