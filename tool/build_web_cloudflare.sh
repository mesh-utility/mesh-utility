#!/usr/bin/env bash
set -euo pipefail

# Build a Cloudflare Pages-ready Flutter web bundle locally.
# Usage:
#   WORKER_URL="https://your-worker.workers.dev" ./tool/build_web_cloudflare.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORKER_URL="${WORKER_URL:-https://mesh-utility-worker.aaffiliate796.workers.dev}"
BASE_HREF="${BASE_HREF:-/}"

echo "Building Flutter web bundle..."
echo "  WORKER_URL=${WORKER_URL}"
echo "  BASE_HREF=${BASE_HREF}"

flutter build web \
  --release \
  --base-href "${BASE_HREF}" \
  --dart-define=WORKER_URL="${WORKER_URL}"

if [[ ! -f "build/web/_redirects" ]]; then
  cp web/_redirects build/web/_redirects
fi
if [[ ! -f "build/web/_headers" ]]; then
  cp web/_headers build/web/_headers
fi

echo "Done. Output ready at: build/web"
echo "Local smoke test:"
echo "  python3 -m http.server 8080 --directory build/web"
