# Mesh Utility Alpha-20

## Contact sync
- Every contact on the radio is now counted, including contacts with emoji, non-Latin, one-character or empty names. Previously these were dropped, so large lists stopped a few percent short (for example 829/899 or 323/350).
- Contacts now load in a single pass, following the MeshCore companion protocol: one request, every contact frame, finished when the radio reports the end of the list. The retry, resume and timer logic from Alpha-19 has been removed.
- Final status always shows: complete, incomplete (the radio reported it was busy), or "Bluetooth disconnected" if the link drops mid-sync.

## Releases
- The website now deploys only when a full release is published.
- New full releases are announced on Discord automatically.

## Updating
- Alpha-19 and later can update from inside the app (Settings > App updates).
- Alpha-17 and Alpha-18 can't update themselves: install this APK once by hand, or use Obtainium.

[Add to Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium://add/https://github.com/mesh-utility/mesh-utility)
