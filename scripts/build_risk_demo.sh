#!/usr/bin/env bash
# Bundle the shared trade-ticket risk functions into the standalone public page.
set -euo pipefail
cd "$(dirname "$0")/.."
pnpm dlx esbuild@0.28.2 docs/public-demo/live.ts --bundle --format=esm --outfile=docs/public-demo/live.js
node --experimental-strip-types app/scripts/risk.test.ts
