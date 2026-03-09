# Contributing

Thanks for contributing to Mesh Utility.

## Development Setup

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

- Create feature branches from `mesh-utility`.
- Keep PRs focused and small where possible.
- Include logs/screenshots for UI, BLE, and map behavior changes.
- Reference issue IDs when applicable.

## Required Checks

Before opening a PR:

```bash
flutter analyze
flutter test
cd worker && npm run check
```

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

- Do not commit secrets or credentials.
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

