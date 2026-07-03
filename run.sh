#!/usr/bin/env bash
# =============================================================================
# run.sh — resilient wrapper around export-chatgpt (brianjlacy/export-chatgpt)
#
# Runs in an INFINITE loop until the export finishes successfully (exit 0).
# - success (exit 0)         -> ends the loop and prints DONE
# - 429 / rate limit         -> waits 5 minutes and retries
# - expired/invalid token    -> prints "NEED A NEW TOKEN" and checks token.txt
#                               mtime every 30s; continues once it changes
# - other/transient error    -> waits 5 minutes and retries
#
# SAFETY: works strictly inside its own folder. NEVER uses --update.
#         The token is passed via an env variable (never leaks into `ps`).
# =============================================================================
set -uo pipefail

# base-dir = location of this script (works for any folder name)
EXPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_FILE="$EXPORT_DIR/token.txt"
OUT_DIR="$EXPORT_DIR/out"
LOG="$EXPORT_DIR/export.log"
TOOL="$EXPORT_DIR/tool/export-chatgpt.js"
THROTTLE=15
RETRY_WAIT=300      # 5 minutes on rate limit / other error
TOKEN_POLL=30       # token.txt poll interval while waiting for an expired token

ts()      { date '+%Y-%m-%d %H:%M:%S'; }
logmsg()  { echo "[$(ts)] $*" | tee -a "$LOG"; }

# Reads the token from the file and trims whitespace / newlines / a leading "Bearer ".
read_token() {
  tr -d '\r\n' < "$TOKEN_FILE" 2>/dev/null \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^[Bb]earer[[:space:]]*//'
}

# Extracts chatgpt_account_id from the JWT (works for any plan, incl. Business).
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

# Extracts the plan type from the JWT (log diagnostics only).
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

# Waits until token.txt changes (mtime) and is non-empty.
wait_for_new_token() {
  local old_mtime cur_mtime tok
  old_mtime="$(stat -c %Y "$TOKEN_FILE" 2>/dev/null || echo 0)"
  logmsg "⚠️  NEED A NEW TOKEN"
  {
    echo ""
    echo "############################################################"
    echo "#                                                          #"
    echo "#   ⚠️   NEED A NEW TOKEN                                   #"
    echo "#                                                          #"
    echo "#   Paste a fresh Bearer token (eyJ...) into the file:     #"
    echo "#   $TOKEN_FILE"
    echo "#                                                          #"
    echo "#   Checking every ${TOKEN_POLL}s ...                                 #"
    echo "#                                                          #"
    echo "############################################################"
    echo ""
  } | tee -a "$LOG"

  while true; do
    sleep "$TOKEN_POLL"
    cur_mtime="$(stat -c %Y "$TOKEN_FILE" 2>/dev/null || echo 0)"
    tok="$(read_token)"
    if [ "$cur_mtime" != "$old_mtime" ] && [ -n "$tok" ]; then
      logmsg "✅ Detected token.txt change — resuming the export."
      return 0
    fi
  done
}

logmsg "==================================================================="
logmsg "=== Start run.sh | throttle=${THROTTLE}s | out=$OUT_DIR ==="
logmsg "==================================================================="

attempt=0
while true; do
  attempt=$((attempt + 1))

  TOKEN="$(read_token)"
  if [ -z "$TOKEN" ]; then
    logmsg "token.txt is empty."
    wait_for_new_token
    continue
  fi

  # Account-id from the JWT (more robust than the tool's built-in auto-detection).
  ACC="$(extract_account_id "$TOKEN")"
  PLAN="$(extract_plan_type "$TOKEN")"
  ACC_ARGS=()
  if [ -n "$ACC" ]; then
    ACC_ARGS=(--account-id "$ACC")
    logmsg "Plan='$PLAN' | account-id from JWT='$ACC' (passing --account-id)"
  else
    logmsg "Plan='$PLAN' | could not extract account-id from JWT — leaving the tool's auto-detection."
  fi

  logmsg "--- Attempt #$attempt: launching export-chatgpt via the browser (Playwright/xvfb) ---"

  # The export runs via browser-export.js: the tool's HTTP is routed through a
  # real browser (Chromium) that passes the Cloudflare "managed challenge".
  # NOTE: NEVER --update! The token goes via an env variable. The flags
  # (--throttle, --include-archived, --output, --account-id) live in browser-export.js.
  CHATGPT_BEARER_TOKEN="$TOKEN" ACC="$ACC" \
  PLAYWRIGHT_BROWSERS_PATH="$EXPORT_DIR/pw/browsers" \
    xvfb-run -a node "$EXPORT_DIR/pw/browser-export.js" 2>&1 | tee -a "$LOG"
  rc=${PIPESTATUS[0]}

  logmsg "--- Attempt #$attempt finished with exit code: $rc ---"

  # Success = exit 0 (full pass completed).
  if [ "$rc" -eq 0 ]; then
    logmsg "✅✅✅ DONE — export finished successfully. Ending the loop. ✅✅✅"
    echo "DONE"
    break
  fi

  # Analyze the last log lines to disambiguate the failure cause.
  tail_out="$(tail -n 60 "$LOG" 2>/dev/null)"

  # 1) Expired / invalid token (auth).
  if echo "$tail_out" | grep -qiE 'BX_AUTH_FAIL|Authentication failed|token may be expired|Token expired|requires --bearer|not authenticated|invalid token|Bearer token may be expired'; then
    logmsg "Cause: expired / invalid token (auth) — waiting for a new token."
    wait_for_new_token
    continue
  fi

  # 2) Rate limit (429) — wait 5 min and retry.
  if echo "$tail_out" | grep -qiE 'Rate limited|\b429\b|too many requests|rate.?limit'; then
    logmsg "Cause: rate limit (429) — waiting ${RETRY_WAIT}s and retrying."
    sleep "$RETRY_WAIT"
    continue
  fi

  # 3) Other / transient error — wait 5 min and retry (resilience, we don't give up).
  logmsg "Cause: other/transient error (rc=$rc) — waiting ${RETRY_WAIT}s and retrying."
  sleep "$RETRY_WAIT"
done

logmsg "=== run.sh finished (export done) ==="
