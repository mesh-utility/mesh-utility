# AGENTS

Guidance for coding agents and contributors working in this repository.

## Priorities

1. Preserve user-visible behavior unless explicitly changing it.
2. Keep BLE, map, sync, and storage logic deterministic and observable via logs.
3. Prefer small, verifiable changes with clear rollback paths.

## Repo Conventions

- Flutter app code: `lib/`
- Worker code: `worker/`
- Web build helper: `tool/build_web_cloudflare.sh`
- CI/CD workflows: `.github/workflows/`

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

## Safety Rules

- Never commit secrets.
- Never run destructive git commands unless explicitly requested.
- Prefer non-interactive git commands.

## Validation Checklist

For non-trivial changes, validate:

- `flutter analyze`
- `flutter test` (when feasible)
- worker check: `cd worker && npm run check`
- targeted runtime smoke logs for touched paths

