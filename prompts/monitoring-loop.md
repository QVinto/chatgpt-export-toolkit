# Monitoring loop — prompt (template)

This is a prompt for an **AI agent** (e.g. Claude Code) run by cron/scheduler at an
interval that depends on the phase (30 min for a stable run; 1–5 min for probe/end/cooldown).
Before use, replace the placeholders:

- `<DIR>` → absolute path of the working folder (e.g. `~/chatgpt-export-myaccount`)
- `<SESSION>` → tmux session name (e.g. `cgpt` or `cgpt-myaccount`)

> The probe variant (15 s → 65 s on the first 429) is included in **STEP B** below; for a
> standard 65 s run the branch with `stepdown-controller.sh` is used.

---

```
Monitoring + STEP controller for the ChatGPT export (folder <DIR>, tmux "<SESSION>", Playwright browser-export.js). Pace: target/floor 65s, ceiling 90s (the controller drives it); optional 15s probe -> on the first 429 switch to 65s. The throttle is changed ONLY by <DIR>/restart.sh. NEVER edit run.sh while it runs, NEVER two runners, NEVER --update.

STEP 0 — COOLDOWN gate: now=$(date +%s); cool=$(cat <DIR>/.cooldown-until 2>/dev/null||echo 0); is node running? (/proc/*/comm==MainThread with a cmdline containing <DIR>/pw/browser-export). If node is NOT running and now<cool -> report "cooldown until $(date -d @$cool +%H:%M)", END. If node is NOT running and now>=cool -> verify token.txt is non-empty; restart bash <DIR>/restart.sh "$(cat <DIR>/.throttle)" "$(cat <DIR>/.min-throttle)". If node is running -> A.

STEP A — health: tmux ls|grep <SESSION>; <DIR>/status.sh; new 429/"max retries" since the last "====== RESTART" in <DIR>/export.log. If a token is needed (BX_AUTH_FAIL/Token expired/empty and node NOT running) -> print PROMINENTLY that a Bearer must be pasted into <DIR>/token.txt. NOTE: a fresh token unlocks a hard lockout, but the +1/min refill still applies.

STEP A2 — LOCKOUT (safeguard): if RUNNING but ZERO progress for 2 checks in a row AND many 429/"max retries" -> stop the runner (kill tmux <SESSION> + chromium with <DIR>/pw/userdata + the matching xvfb, rm <DIR>/pw/userdata/Singleton*), echo 90><DIR>/.throttle, echo 90><DIR>/.min-throttle, echo $(( $(date +%s)+3600 ))><DIR>/.cooldown-until, report and suggest a fresh token. DO NOT RESTART.

STEP 5 — DONE only if the log has "DONE"/Export Complete AND node exit 0 AND downloaded > 0 and the count ≈ "Conversations in main index" from status.sh. If exit 0 but downloaded << index (errors) -> FALSE, handle as A2. If real: <DIR>/verify.sh; if OK -> ZIP <DIR>/chatgpt-export-$(date +%F).zip from out/, summary, END the loop (remove this cron + notification). END.

STEP B — PACE: th=$(cat <DIR>/.throttle); n429 = count of new "Rate limited|max retries" since the last "====== RESTART".
  - If th=15 AND n429>=1 -> FIRST 429 in the probe: bash <DIR>/restart.sh 65 65; verify 1 runner; echo 0 > <DIR>/.stable-count; report "first 429 at 15s -> switched to 65s".
  - If th=15 AND n429=0 -> STAY (exploiting the bucket at 15s).
  - If th!=15 -> bash <DIR>/stepdown-controller.sh; per DECISION: SET_65->restart.sh 65 65; SET_90->restart.sh 90 90; STAY->nothing. (After a restart verify 1 runner + echo 0 > <DIR>/.stable-count.)

STEP C — report (English): status, downloaded count, throttle (cat <DIR>/.throttle), 429, what you did (STAY/switch/cooldown). One cron.
```
