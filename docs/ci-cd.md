# CI/CD Setup

This repository uses four GitHub Actions workflows:

- `CI` (`.github/workflows/ci.yml`): static checks/tests only, no release builds.
- `Deploy` (`.github/workflows/deploy.yml`): deploys Cloudflare Worker + Flutter web to Cloudflare Pages.
- `iOS Archive` (`.github/workflows/ios-ipa.yml`): builds an unsigned iOS archive on GitHub `published`/`prereleased` releases without requiring signing certificates, and can also be run manually for an existing release tag.
- `Release Artifacts` (`.github/workflows/release-artifacts.yml`): on GitHub `published`/`prereleased` releases, builds Android/Linux/Windows/macOS/web and attaches non-web artifacts to the release page.

## 1) Required GitHub Secrets

Add these in **GitHub → Settings → Secrets and variables → Actions**:

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`

Recommended Cloudflare token scopes:

- `Workers Scripts:Edit`
- `Workers KV/D1/Durable Objects` as needed by the worker
- `Pages:Edit`
- Account scope limited to your Cloudflare account only

## 2) Required Cloudflare Worker Secret

Set this once (outside git):

```bash
cd worker
npx wrangler secret put GITHUB_TOKEN
```

`GITHUB_TOKEN` is consumed by the worker runtime, not GitHub Actions.

## 3) Environment Protection

Create a GitHub Environment named `production` and configure:

- Required reviewers for deployment approvals
- Optional wait timer
- Restrict deployment branches to `mesh-utility`

The deploy workflow already targets `environment: production`.

## 4) Branch Protection

Protect branch `mesh-utility`:

- Require PR before merge
- Require status checks to pass:
  - `Flutter Analyze & Test`
  - `Worker Type Check`
- Restrict force-push and deletion

## 5) Deploy Trigger Behavior

`deploy.yml` triggers on:

- push to `mesh-utility`
- manual `workflow_dispatch`

Deployment steps:

1. Deploy worker (`worker/` via Wrangler)
2. Build Flutter web (`tool/build_web_cloudflare.sh`)
3. Deploy `build/web` to Cloudflare Pages project `mesh-utility-tracker` on branch `mesh-utility`

## 6) Release Artifact Behavior

`release-artifacts.yml` triggers on:

- `release.published`
- `release.prereleased`

`ios-ipa.yml` uses the same release trigger types to keep release builds aligned under one event source.

Build matrix:

- Android (`flutter build apk --release`)
- Linux (`flutter build linux --release`)
- Windows (`flutter build windows --release`)
- macOS (`flutter build macos --release --no-codesign`)
- Web (`flutter build web --release`) for verification only

iOS release workflow:

- iOS (`flutter build ipa --release --no-codesign`)
- Packages the resulting `.xcarchive` as `mesh-utility-<tag>-ios-xcarchive.tar.gz`
- Uploads that tarball as both a workflow artifact and a GitHub release asset
- Can be manually dispatched with a `release_tag` input to backfill an existing release

Uploaded to release page (web excluded):

- `mesh-utility-<tag>-android.apk`
- `mesh-utility-<tag>-linux-x64.tar.gz`
- `mesh-utility-<tag>-windows-x64.zip`
- `mesh-utility-<tag>-macos.tar.gz`
- `SHA256SUMS.txt`

## 7) Open-Source Safety Rules

- Never commit secrets, tokens, private keys, or `.env` values.
- Keep examples only (`.env.example`, docs with placeholders).
- Use GitHub secret scanning and push protection.
- Rotate secrets immediately if leaked.

## 8) Quick Validation

After deploy:

```bash
curl -I https://mesh-utility.org
curl -I https://mesh-utility-worker.aaffiliate796.workers.dev/health
```

From browser console on `https://mesh-utility.org`, verify no CORS errors for:

- `.../history`
- `.../scans`
