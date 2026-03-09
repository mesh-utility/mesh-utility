# Flutter Best Practices (Project-Specific)

## Architecture

- Keep business logic in services (`lib/src/services/*`), not widgets.
- Keep transport/protocol logic in `lib/transport/*`.
- Keep widgets declarative and side-effect light.

## State Management

- Central state transitions through `AppState`.
- Always call `notifyListeners()` exactly when UI-relevant state changes.
- Avoid duplicate async operations with guard flags.

## Async and Errors

- Wrap network/BLE operations in `try/catch` and provide actionable status text.
- Preserve recoverability:
  - failed uploads should keep local queue
  - transient BLE failures should not corrupt state

## Platform Awareness

- Gate behavior by platform (`kIsWeb`, `defaultTargetPlatform`) only where needed.
- Web BLE requires secure context and browser support; always show clear status.
- Keep Linux pairing-specific behavior isolated to Linux path.

## UI/UX

- Prevent overflow at larger text scales and small viewports.
- Use `Expanded`/`Flexible`/scroll containers where content can grow.
- Keep status and control labels explicit (avoid ambiguous states).

## Performance

- Avoid heavy work on UI thread during frame-critical interactions.
- Use cached derived data where practical.
- Avoid unnecessary rebuilds from broad state changes.

## Data and Sync

- Keep sync time anchored to trusted internet/server time where required.
- Preserve offline-first behavior and explicit offline mode semantics.
- Treat worker as source for cloud history; local store as source for unsynced scans.

## Logging and Diagnostics

- Keep logs structured and searchable by feature tag.
- Log key transitions:
  - scan start/stop
  - connect/disconnect
  - sync start/finish/failure
  - delete flow start/finish/failure

## Testing Guidance

- Prefer unit tests for protocol/signal-classification/business rules.
- Add regression tests for parsing/classification bugs.
- For platform-specific paths, include manual test notes in PR description.

