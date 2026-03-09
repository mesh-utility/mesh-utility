# Mesh Utility (Flutter)

Flutter conversion of `mesh-utility-tracker`, created in a separate folder as requested.

## Platforms

This project is scaffolded for:
- Android
- iOS
- Web
- Windows
- macOS
- Linux

## Current Ported Features

- Coverage map with hex zone rendering
- Worker sync for `/history`, `/history/{day}.ndjson`, and `/coverage`
- Local scan cache fallback
- Nodes view with search and latest signal snapshot
- History view with node filtering
- Settings for Worker URL, history days, scan interval, smart scan, and offline mode
- Manual and Privacy pages

## Run

```bash
cd /home/chris/Projects/mesh-utility
flutter pub get
flutter run
```

## Notes

- BLE radio connection logic from the web app has not yet been ported to Flutter plugins in this initial conversion.
- The app is structured so BLE service integration can be added without changing page architecture.
