# AGENTS

Guidance for coding agents and contributors working in this repository.

## Priorities

1. Preserve user-visible behavior unless explicitly changing it.
2. Keep BLE, map, sync, and storage logic deterministic and observable via logs.
3. Prefer small, verifiable changes with clear rollback paths.

## Repo Conventions

- Flutter app code: `lib/`
- Tests: `test/`
- Worker code: `worker/`
- Web build helper: `tool/build_web_cloudflare.sh`
- CI/CD workflows: `.github/workflows/`
- Do not commit build artifacts (e.g., anything in `build/`, `.dart_tool/`, or platform `ephemeral/` directories).
- After editing any file, run `dart format .` before continuing.

## Architecture notes (current)

- **Chunked map build:** `lib/src/pages/map_page.dart` builds zones in slices of about 1500 and yields to the browser between slices. A generation counter cancels outdated builds. A "Loading map..." pill shows after 300 ms and never blocks taps.
- **Viewport render:** only hexes in view are drawn (`_batchHexes`). A pan schedules a debounced render. The previous hexes stay drawn and tappable until the new render lands.
- **Settle-debounced fetch:** hex data is fetched about 400 ms after the map settles. Overlapping requests are queued and identical ones are deduplicated. A fetch that returns the same cells must not change dataset identity.
- **Taps:** exact hit test first, then the nearest hex centre (`lib/src/services/hex_tap_target.dart`). An empty tap during a pending render does not close the popup, and the open popup survives a zone-list swap when its cell still exists.
- **SNR filter:** `lib/src/services/snr_filter.dart`. Presets are Weak (-7 dB and below), OK (-7 to 0), Strong (above 0), plus a custom range. The filter is stored in settings and shown as a chip on the map. Dead zones are hidden while it is on.
- **Back button:** a popup closes first, then back returns to the tab you came from, and on the main map it sends the app to the background (the app keeps running).
- **Scan-to-map:** opening the map from Scans uses the same chunked load and a point-id lookup instead of scanning every hex.
- Hexes are never resized, merged or moved. See `docs/flutter-best-practices.md` for speed rules.

## Localization Rules

- If new localization keys are added/renamed in `lib/l10n/app_en.arb`, run `python3 tool/translate.py --in lib/l10n/app_en.arb --l10n-dir lib/l10n --missing-only` before `flutter gen-l10n`, `flutter pub get`, or any command that regenerates localization files.
- Use TranslateGemma Cloud GLM 5 latest via `--model translategemma:glm-5-cloud` (example: `python3 tool/translate.py --in lib/l10n/app_en.arb --l10n-dir lib/l10n --missing-only --model translategemma:glm-5-cloud`).
- `tool/translate.py` uses the Ollama API (default `http://localhost:11434`), so ensure Ollama is running and the model is pulled first (for example: `ollama pull translategemma:glm-5-cloud`).
- Because model pull and translation runs can be lengthy, agents should offer the user exact copy/paste commands to run locally instead of waiting on long agent-run sessions.
- Do not commit localization generation output that leaves newly added keys in English in non-English `.arb` files unless that fallback is intentional and reviewed.

## Logging

- Use structured tags already present in the app (`[info] [sync] ...`, etc.).
- Avoid removing existing diagnostic logs unless replacing with equal/better signal.
- For new critical flows, log start/success/failure with enough context.

## BLE Rules

- Do not regress Linux pairing flow.
- Keep Android and web BLE behavior explicit by platform.
- For web BLE, assume HTTPS requirement and browser variability.

## Sync/Data Rules

- Worker sync must tolerate offline mode and recover cleanly.
- Preserve local scan queue on upload failure.
- Do not change scan ownership semantics unintentionally.

## UI Rules

- Avoid introducing layout overflows at common text scales.
- Respect existing design language unless task explicitly requests redesign.
- Maintain mobile and desktop usability.

## Performance Rules

The goal is to make the app as fast and responsive as possible.

- **Minimize Widget Rebuilds:**
  - Use `const` constructors for widgets and data wherever possible.
  - Define static or unchanging data (like lists of configuration) outside of `build()` methods to prevent re-allocation on every render.
- **Efficient Lists:**
  - For long or dynamic lists, always prefer `ListView.builder` or `SliverList` to build items lazily as they scroll into view.
- **Isolate Expensive Work:**
  - Use `Isolate.run()` or `compute()` for any CPU-intensive tasks (e.g., large data processing, complex calculations) to keep the UI thread from freezing.
- **Profile Before Optimizing:**
  - Use Flutter DevTools to identify real performance bottlenecks (CPU, memory, rendering). Do not guess. Focus optimizations on measured hotspots.

## Memory Management

- **Resource Disposal:**
  - Always `dispose()` controllers (Text, Scroll, Animation) and cancel StreamSubscriptions when widgets are destroyed to prevent leaks.
- **Image Optimization:**
  - Use `cacheWidth` and `cacheHeight` when loading network or asset images to avoid decoding full-resolution images into memory for small thumbnails.
- **Transient Data:**
  - Avoid persisting large datasets to the local database if they are only needed for a single session.
  - For large D1 queries, consider fetching paginated data on-demand and holding it only in ephemeral state (RAM).

## Safety Rules

- Never commit secrets.
- Never run destructive git commands unless explicitly requested.
- Prefer non-interactive git commands.

## Validation Checklist

For non-trivial changes, validate:

- `dart format .` (exactly like that, not file targeted ,after each file edit)
- `flutter analyze`
- `flutter test` (when feasible)
- worker check: `cd worker && npm run check`
- targeted runtime smoke logs for touched paths
