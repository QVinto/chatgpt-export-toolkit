# Token-wait loop — prompt (template)

A prompt for an AI agent run by cron ~every **5 h** that waits until the user pastes a
Bearer token, **max 10 attempts** (~50 h). Once the token is present → it starts the export
and switches to the monitoring loop (`monitoring-loop.md`). Replace the placeholders:

- `<DIR>` → absolute path of the working folder
- `<SESSION>` → tmux session name
- `<MONITOR_PROMPT>` → the full text from `monitoring-loop.md` (with `<DIR>`/`<SESSION>` filled in)

---

```
TOKEN-WAIT loop — folder <DIR>, tmux "<SESSION>". Goal: wait for a Bearer token (the user pastes it into <DIR>/token.txt), max 10 attempts of ~5h each, then start the export and switch to monitoring. One cron.

STEP 1 — try to start: out=$(bash <DIR>/wait-and-start.sh 2>&1); print the whole out (it contains ACCOUNT_ID/PLAN/TOKEN_EXP + STATUS=... on the last line). Note: wait-and-start.sh uses EXPORT_SESSION; run it as: EXPORT_SESSION=<SESSION> bash <DIR>/wait-and-start.sh

STEP 2 — evaluate STATUS from the last line:

(A) STATUS=STARTED or STATUS=ALREADY_RUNNING -> the token is valid and the export is running:
  1) Verify a single runner: tmux ls | grep <SESSION>.
  2) Remove THIS wait-cron.
  3) Create the MONITORING cron (interval 30 min, or 1-5 min for a probe) with the prompt: <MONITOR_PROMPT>.
  4) echo 0 > <DIR>/.wait-count
  5) Report (English; include ACCOUNT_ID, that the export is running) + notification. Run the first monitoring check right away. END.

(B) STATUS=NO_TOKEN or STATUS=BAD_TOKEN -> the (valid) token is not there yet:
  1) c=$(( $(cat <DIR>/.wait-count 2>/dev/null||echo 0) + 1 )); echo $c > <DIR>/.wait-count
  2) If c -ge 10 -> Report "After 10 attempts (~50h) still no valid token, ending the wait." ; remove this cron ; notification. END.
  3) Otherwise -> Report "Waiting for a token (attempt c/10). Paste a Bearer (eyJ...) into <DIR>/token.txt. Next check in ~5h." END.

(C) STATUS=START_FAILED -> the restart failed: report, check tmux + tail <DIR>/export.log, DO NOT increment wait-count, try on the next firing. END.
```
