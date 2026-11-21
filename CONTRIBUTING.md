# Contributing

Thanks for contributing to Mesh Utility.

By contributing you agree that your contribution is licensed under the [GNU General Public License v3.0](./LICENSE) (GPL-3.0-only), the same as the rest of the project.

## Development Setup

Toolchain used by the project:

- Flutter 3.50.1 (pinned in `.flutter-version`; CI and release builds read it)
- Gradle 9.3.1, Android Gradle Plugin 9.1.1, Kotlin 2.4.10 (already set in `android/`)
- Java 17 (Temurin, as in the release workflow)
- Node 20 for the Worker

```bash
flutter pub get
flutter run
```

Worker setup:

```bash
cd worker
npm ci
npm run check
```

## Branching and PRs

- Fork the repo or create a feature branch from `main`.
- Open pull requests to `main`. CI (`Flutter Analyze & Test` and `Worker Type Check`) must pass before merge.
- Keep PRs focused and small where possible.
- Include logs/screenshots for UI, BLE, and map behavior changes.
- Reference issue IDs when applicable.

## Required Checks

Before opening a PR:

```bash
dart format .
flutter analyze
flutter test
cd worker && npm run check
```

Formatting policy:

- Run `dart format .` after every file edit, not only at PR time.

PRs should pass CI:

- Flutter analyze/test
- Worker type-check

## Commit Guidelines

- Use clear commit messages in imperative voice.
- Suggested format:
  - `feat: add ...`
  - `fix: correct ...`
  - `chore: update ...`
  - `docs: add ...`

## Security

- Do not commit secrets, tokens, keystores or `.env` values.
- Use GitHub Actions Secrets and Cloudflare secrets.
- Report security-sensitive issues privately.

## BLE and Platform Changes

When changing BLE behavior, test at minimum:

- Android native
- Linux desktop
- Web on Android Chrome (HTTPS)

If web behavior is changed, include browser/platform tested and exact logs for failures.

## Documentation

If you change behavior, update:

- `README.md` for user-facing flow
- `docs/ci-cd.md` for deployment changes
- `docs/flutter-best-practices.md` for architecture/style impacts
- `AGENTS.md` for architecture notes

The Worker lives in `worker/` (Cloudflare Worker and D1). See `worker/README.md`.
