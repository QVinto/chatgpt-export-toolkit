#!/usr/bin/env bash
# =============================================================================
# run.sh — odolný wrapper pre export-chatgpt (brianjlacy/export-chatgpt)
#
# Beží v NEKONEČNEJ slučke, kým sa export úspešne nedokončí (exit 0).
# - úspech (exit 0)          -> ukončí slučku a oznámi HOTOVO
# - 429 / rate limit         -> počká 5 minút a skúsi znova
# - vypršaný/neplatný token  -> vypíše "POTREBUJEM NOVÝ TOKEN" a každých 30 s
#                               kontroluje mtime token.txt; po zmene pokračuje
# - iná/prechodná chyba      -> počká 5 minút a skúsi znova
#
# BEZPEČNOSŤ: pracuje výhradne v ~/chatgpt-export/. NIKDY nepoužíva --update.
#             Token sa odovzdáva cez env premennú (neuniká do `ps`).
# =============================================================================
set -uo pipefail

# base-dir = umiestnenie tohto skriptu (funguje pre akýkoľvek priečinok, napr. -janka)
EXPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_FILE="$EXPORT_DIR/token.txt"
OUT_DIR="$EXPORT_DIR/out"
LOG="$EXPORT_DIR/export.log"
TOOL="$EXPORT_DIR/tool/export-chatgpt.js"
THROTTLE=15
RETRY_WAIT=300      # 5 minút pri rate limite / inej chybe
TOKEN_POLL=30       # interval kontroly token.txt pri vypršanom tokene

ts()      { date '+%Y-%m-%d %H:%M:%S'; }
logmsg()  { echo "[$(ts)] $*" | tee -a "$LOG"; }

# Načíta token zo súboru a oreže biele znaky / nové riadky / prípadný prefix "Bearer ".
read_token() {
  tr -d '\r\n' < "$TOKEN_FILE" 2>/dev/null \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^[Bb]earer[[:space:]]*//'
}

# Vytiahne chatgpt_account_id z JWT (funguje pre akýkoľvek plán vrátane Business).
extract_account_id() {
  node -e '
    try {
      const t = process.argv[1] || "";
      const p = JSON.parse(Buffer.from(t.split(".")[1], "base64url").toString("utf8"));
      const a = p["https://api.openai.com/auth"] || {};
      process.stdout.write(a.chatgpt_account_id || "");
    } catch (e) { process.stdout.write(""); }
  ' "$1" 2>/dev/null
}

# Vytiahne typ plánu z JWT (len pre diagnostiku v logu).
extract_plan_type() {
  node -e '
    try {
      const t = process.argv[1] || "";
      const p = JSON.parse(Buffer.from(t.split(".")[1], "base64url").toString("utf8"));
      const a = p["https://api.openai.com/auth"] || {};
      process.stdout.write(a.chatgpt_plan_type || "");
    } catch (e) { process.stdout.write(""); }
  ' "$1" 2>/dev/null
}

# Čaká, kým sa token.txt zmení (mtime) a bude neprázdny.
wait_for_new_token() {
  local old_mtime cur_mtime tok
  old_mtime="$(stat -c %Y "$TOKEN_FILE" 2>/dev/null || echo 0)"
  logmsg "⚠️  POTREBUJEM NOVÝ TOKEN"
  {
    echo ""
    echo "############################################################"
    echo "#                                                          #"
    echo "#   ⚠️   POTREBUJEM NOVÝ TOKEN                              #"
    echo "#                                                          #"
    echo "#   Vlož čerstvý Bearer token (eyJ...) do súboru:          #"
    echo "#   $TOKEN_FILE"
    echo "#                                                          #"
    echo "#   Kontrolujem každých ${TOKEN_POLL}s ...                          #"
    echo "#                                                          #"
    echo "############################################################"
    echo ""
  } | tee -a "$LOG"

  while true; do
    sleep "$TOKEN_POLL"
    cur_mtime="$(stat -c %Y "$TOKEN_FILE" 2>/dev/null || echo 0)"
    tok="$(read_token)"
    if [ "$cur_mtime" != "$old_mtime" ] && [ -n "$tok" ]; then
      logmsg "✅ Detegovaná zmena token.txt — pokračujem v exporte."
      return 0
    fi
  done
}

logmsg "==================================================================="
logmsg "=== Štart run.sh | throttle=${THROTTLE}s | out=$OUT_DIR ==="
logmsg "==================================================================="

attempt=0
while true; do
  attempt=$((attempt + 1))

  TOKEN="$(read_token)"
  if [ -z "$TOKEN" ]; then
    logmsg "Token.txt je prázdny."
    wait_for_new_token
    continue
  fi

  # Account-id z JWT (robustnejšie než vstavaná auto-detekcia nástroja).
  ACC="$(extract_account_id "$TOKEN")"
  PLAN="$(extract_plan_type "$TOKEN")"
  ACC_ARGS=()
  if [ -n "$ACC" ]; then
    ACC_ARGS=(--account-id "$ACC")
    logmsg "Plán='$PLAN' | account-id z JWT='$ACC' (odovzdávam --account-id)"
  else
    logmsg "Plán='$PLAN' | account-id sa nepodarilo vytiahnuť z JWT — nechávam auto-detekciu nástroja."
  fi

  logmsg "--- Pokus #$attempt: spúšťam export-chatgpt cez prehliadač (Playwright/xvfb) ---"

  # Export beží cez browser-export.js: HTTP nástroja sa prepošle cez reálny
  # prehliadač (Chromium), ktorý prejde Cloudflare "managed challenge".
  # POZOR: NIKDY --update! Token ide cez env premennú. Flagy (--throttle 30,
  # --include-archived, --output, --account-id) sú zabudované v browser-export.js.
  CHATGPT_BEARER_TOKEN="$TOKEN" ACC="$ACC" \
  PLAYWRIGHT_BROWSERS_PATH="$EXPORT_DIR/pw/browsers" \
    xvfb-run -a node "$EXPORT_DIR/pw/browser-export.js" 2>&1 | tee -a "$LOG"
  rc=${PIPESTATUS[0]}

  logmsg "--- Pokus #$attempt skončil s exit kódom: $rc ---"

  # Úspech = exit 0 (plný prechod dokončený).
  if [ "$rc" -eq 0 ]; then
    logmsg "✅✅✅ HOTOVO — export úspešne dokončený. Ukončujem slučku. ✅✅✅"
    echo "HOTOVO"
    break
  fi

  # Analýza posledných riadkov logu na rozlíšenie príčiny zlyhania.
  tail_out="$(tail -n 60 "$LOG" 2>/dev/null)"

  # 1) Vypršaný / neplatný token (auth).
  if echo "$tail_out" | grep -qiE 'BX_AUTH_FAIL|Authentication failed|token may be expired|Token expired|requires --bearer|not authenticated|invalid token|Bearer token may be expired'; then
    logmsg "Príčina: vypršaný / neplatný token (auth) — čakám na nový token."
    wait_for_new_token
    continue
  fi

  # 2) Rate limit (429) — počkaj 5 min a skús znova.
  if echo "$tail_out" | grep -qiE 'Rate limited|\b429\b|too many requests|rate.?limit'; then
    logmsg "Príčina: rate limit (429) — čakám ${RETRY_WAIT}s a skúšam znova."
    sleep "$RETRY_WAIT"
    continue
  fi

  # 3) Iná / prechodná chyba — počkaj 5 min a skús znova (odolnosť, nevzdávame sa).
  logmsg "Príčina: iná/prechodná chyba (rc=$rc) — čakám ${RETRY_WAIT}s a skúšam znova."
  sleep "$RETRY_WAIT"
done

logmsg "=== run.sh ukončený (export hotový) ==="
