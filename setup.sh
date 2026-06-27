#!/usr/bin/env bash
# =============================================================================
# setup.sh — bootstrap pracovného priečinka pre odolný ChatGPT export.
#
# Pripraví VŠETKO okrem tokenu:
#   1) naklonuje upstream nástroj brianjlacy/export-chatgpt do ./tool (pinnutý commit)
#   2) nainštaluje Playwright + Chromium do ./pw
#   3) vytvorí stavové súbory, out/ a prázdny token.txt
#
# Spúšťať z koreňa pracovného priečinka (kópie tohto repa):  bash setup.sh
# Token sa NEVKLADÁ tu — vlož ho až keď budeš spúšťať (viď README / docs/REPRODUCE.md).
# =============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

TOOL_REPO="https://github.com/brianjlacy/export-chatgpt"
TOOL_COMMIT="4cfc3f2"          # overený funkčný commit (jún 2026)
DEFAULT_THROTTLE="${1:-65}"    # cieľové tempo (s/dopyt); pre úplne čerstvý malý účet zváž 15 (probe)

echo "==> 1/4  Upstream nástroj (./tool)"
if [ ! -d tool/.git ]; then
  git clone "$TOOL_REPO" tool
  git -C tool checkout "$TOOL_COMMIT" 2>/dev/null || echo "    (commit $TOOL_COMMIT nedostupný, ostávam na HEAD)"
else
  echo "    tool/ už existuje — preskakujem klon"
fi

echo "==> 2/4  Playwright + Chromium (./pw)"
( cd pw && npm install )
( cd pw && PLAYWRIGHT_BROWSERS_PATH="$DIR/pw/browsers" npx playwright install chromium )

echo "==> 3/4  Stavové súbory + out/"
printf '%s' "$DEFAULT_THROTTLE" > .throttle
printf '%s' "$DEFAULT_THROTTLE" > .min-throttle
printf 0 > .cooldown-until
printf 0 > .stable-count
printf 0 > .last-count
printf 0 > .wait-count
mkdir -p out
: > export.log

echo "==> 4/4  token.txt (prázdny, práva 600)"
if [ ! -f token.txt ]; then : > token.txt; fi
chmod 600 token.txt

cat <<EOF

✅ Hotovo. Pracovný priečinok je pripravený: $DIR
   cieľové tempo: ${DEFAULT_THROTTLE}s/dopyt

Ďalší krok:
   1) Vlož Bearer token (eyJ...) do:  $DIR/token.txt
   2) Spusti bežca:                   EXPORT_SESSION=cgpt bash $DIR/restart.sh $DEFAULT_THROTTLE $DEFAULT_THROTTLE
   3) Sleduj:                         bash $DIR/status.sh   |   tmux attach -t cgpt
   4) (voliteľne) Webový prehliadač:  VIEWER_PORT=8765 node $DIR/viewer/server.js

Automatické monitorovanie (odporúčané) — viď docs/MONITORING-LOOP.md a prompts/.
EOF
