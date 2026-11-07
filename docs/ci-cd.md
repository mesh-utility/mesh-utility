# CI/CD

This repository has three GitHub Actions workflows:

- `CI` (`.github/workflows/ci.yml`): analyze and test on pull requests and branch pushes. It does not build release artifacts.
- `Deploy` (`.github/workflows/deploy.yml`): when a full release is published (or on a manual run), deploys the Cloudflare Worker and the Flutter web app to Cloudflare Pages. Pushes to `main` do not deploy.
- `Announce Release on Discord` (`.github/workflows/discord-release.yml`): when a full release is published, posts its name, notes and download links to Discord using the `DISCORD_RELEASE_WEBHOOK` repository secret. Skipped for prereleases, drafts, or if the secret is missing.
- `Release Artifacts` (`.github/workflows/release-artifacts.yml`): when a GitHub release is published or prereleased, or when re-run by hand with a `release_tag`, builds artifacts and attaches the non-web files to that release.

Publishing a full release tagged `Alpha-N` is what ships Android and Linux downloads. The live site at https://mesh-utility.org updates from the deploy workflow, not from the release-artifact web build.

There is no separate iOS archive workflow. macOS and iOS release jobs are not enabled.

## 1) Required GitHub secrets

In **GitHub → Settings → Secrets and variables → Actions**:

Deploy:

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`

Recommended Cloudflare token scopes:

- Workers Scripts: Edit
- Workers routes on the zone (zone read, plus Workers Routes edit) so `mesh-utility.org/api/*` can be published
- D1 as needed by the worker
- Pages: Edit
- Limit the token to this Cloudflare account

Release signing (Android APK). Names only; never commit the keystore or passwords:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Published APKs use that stable upload key starting with Alpha-12. If the keystore secret is missing, the Android job falls back to debug signing.

## 2) Worker secret

Set once, outside git:

```bash
cd worker
npx wrangler secret put GITHUB_TOKEN
```

`GITHUB_TOKEN` is read by the Worker at runtime. It is not a GitHub Actions secret.

## 3) Environment

The deploy job uses the GitHub Environment `production`.

Deploys run from release tags, so if you add deployment branch rules to the `production` environment, allow tags (for example `Alpha-*`) as well as `main`.

## 4) Branch protection

Protect `main`:

- Require a pull request before merge
- Require status checks:
  - `Flutter Analyze & Test`
  - `Worker Type Check`
- Block force-push and deletion

## 5) Deploy

`deploy.yml` triggers on:

- push to `main`, `master`, or `mesh-utility`
- manual `workflow_dispatch`

Steps:

1. Deploy the Worker from `worker/` with Wrangler (`npm run deploy`).
2. Build Flutter web with `tool/build_web_cloudflare.sh` and `WORKER_URL=https://mesh-utility.org/api`.
3. Deploy `build/web` to the Cloudflare Pages project `mesh-utility-tracker`.

The Pages production branch name in that command is `mesh-utility`. That is the Pages branch, not the git branch. Publishing a release deploys Worker and Pages; a push to git `main` does not.

The Worker serves `https://mesh-utility.org/api/*` (the `/api` prefix is stripped) and keeps `workers.dev` enabled.

## 6) Release artifacts

`release-artifacts.yml` triggers on:

- `release.published`
- `release.prereleased`
- manual `workflow_dispatch` with `release_tag` (rebuild assets for an existing tag)

Current release tags are full releases named `Alpha-N`. Obtainium and the in-app updater follow those releases.

Jobs:

- Android (`flutter build apk --release`), signed with the upload keystore when the secrets above are set
- Linux (`flutter build linux --release`)
- Windows (`flutter build windows --release`) — the job is in the workflow, but a Windows build is not currently available and is not a supported download. The publish job still attaches Android and Linux assets when Android succeeded, even if the Windows job failed.
- Web (`flutter build web --release`) for verification only. The web build is not attached to the release.

Attached to the release when the matching job succeeded:

- `mesh-utility-<tag>-android.apk`
- `mesh-utility-<tag>-linux-x64.tar.gz`
- `SHA256SUMS.txt`
- `mesh-utility-<tag>-windows-x64.zip` only if the Windows job actually produced a file. Do not document or expect that zip while the Windows build is unavailable.

macOS and iOS are not built here.

## 7) Open-source safety

- Never commit secrets, tokens, private keys, keystores, or `.env` values.
- Keep examples only (`wrangler.toml.example`, docs with placeholders).
- Use GitHub secret scanning and push protection.
- Rotate a secret immediately if it leaks.
- Do not put contact names or channel message text in docs, issues, or logs.

## 8) Quick validation

After a deploy:

```bash
curl -I https://mesh-utility.org
curl -I https://mesh-utility.org/api/health
```

From the browser on `https://mesh-utility.org`, worker calls go to `/api/...` (for example `/api/history` and `/api/scans`) and should not fail CORS.
