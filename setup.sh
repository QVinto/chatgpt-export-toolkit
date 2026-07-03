#!/usr/bin/env bash
# =============================================================================
# setup.sh — bootstrap a working folder for the resilient ChatGPT export.
#
# Prepares EVERYTHING except the token:
#   1) clones the upstream tool brianjlacy/export-chatgpt into ./tool (pinned commit)
#   2) installs Playwright + Chromium into ./pw
#   3) creates the state files, out/ and an empty token.txt
#
# Run from the root of the working folder (a copy of this repo):  bash setup.sh
# The token is NOT set here — paste it right before you start (see README / docs/REPRODUCE.md).
# =============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

TOOL_REPO="https://github.com/brianjlacy/export-chatgpt"
TOOL_COMMIT="4cfc3f2"          # verified working commit (June 2026)
DEFAULT_THROTTLE="${1:-65}"    # target pace (s/request); for a brand-new small account consider 15 (probe)

echo "==> 1/4  Upstream tool (./tool)"
if [ ! -d tool/.git ]; then
  git clone "$TOOL_REPO" tool
  git -C tool checkout "$TOOL_COMMIT" 2>/dev/null || echo "    (commit $TOOL_COMMIT unavailable, staying on HEAD)"
else
  echo "    tool/ already exists — skipping clone"
fi

echo "==> 2/4  Playwright + Chromium (./pw)"
( cd pw && npm install )
( cd pw && PLAYWRIGHT_BROWSERS_PATH="$DIR/pw/browsers" npx playwright install chromium )

echo "==> 3/4  State files + out/"
printf '%s' "$DEFAULT_THROTTLE" > .throttle
printf '%s' "$DEFAULT_THROTTLE" > .min-throttle
printf 0 > .cooldown-until
printf 0 > .stable-count
printf 0 > .last-count
printf 0 > .wait-count
mkdir -p out
: > export.log

echo "==> 4/4  token.txt (empty, mode 600)"
if [ ! -f token.txt ]; then : > token.txt; fi
chmod 600 token.txt

cat <<EOF

✅ Done. The working folder is ready: $DIR
   target pace: ${DEFAULT_THROTTLE}s/request

Next steps:
   1) Paste your Bearer token (eyJ...) into:  $DIR/token.txt
   2) Start the runner:                       EXPORT_SESSION=cgpt bash $DIR/restart.sh $DEFAULT_THROTTLE $DEFAULT_THROTTLE
   3) Watch:                                  bash $DIR/status.sh   |   tmux attach -t cgpt
   4) (optional) Web viewer:                  VIEWER_PORT=8765 node $DIR/viewer/server.js

Automated monitoring (recommended) — see docs/MONITORING-LOOP.md and prompts/.
EOF
