# Step-by-step reproduction

## Prerequisites
- Linux, **Node.js ≥ 18** (tested on v24), `git`, `tmux`, `xvfb` (`xvfb-run`).
  - Debian/Ubuntu: `sudo apt install -y git tmux xvfb`
- Access to the target ChatGPT account (your own / with permission).

## 1) Working copy (one folder = one account)
```bash
git clone <this-repo> chatgpt-export-<name>
cd chatgpt-export-<name>
bash setup.sh 65        # 65 s target; fresh small account -> try 15
```
`setup.sh` clones the upstream into `tool/`, installs Playwright+Chromium into `pw/`,
creates the state files, `out/` and an empty `token.txt`.

## 2) Token
Log in to the account in a browser, open `https://chatgpt.com/api/auth/session`, copy
the **`accessToken`** value (`eyJ...`) and paste **only that string** (without "Bearer") into `token.txt`:
```bash
printf '%s' 'eyJ...' > token.txt && chmod 600 token.txt
```
The token is valid for ~a few hours to days; on expiry the loop will ask for a new one.

## 3) Starting
```bash
EXPORT_SESSION=cgpt bash restart.sh 65 65     # or 15 15 for a probe
bash status.sh
tmux attach -t cgpt                            # live log; Ctrl-b d = detach
```
In the log, verify `auth OK — logged in as <email>` (correct account).

## 4) Monitoring loop (recommended)
Deploy the loop (AI agent or cron) as described in [`MONITORING-LOOP.md`](MONITORING-LOOP.md) +
the templates in [`../prompts/`](../prompts/). The loop handles pace, 429, lockout, token expiry
and the final ZIP on its own.

## 5) Completion
After `Export Complete` (`exit 0`, count ≈ index):
```bash
bash verify.sh                                  # content validation
zip -r -1 chatgpt-export-<name>-$(date +%F).zip out
```

## 6) Viewer (optional)
```bash
VIEWER_PORT=8765 node viewer/server.js          # http://localhost:8765 (or via Tailscale)
```

---

## Multiple accounts at once (reference deployment)
Each account = a separate copy of the repo, a **different** `EXPORT_SESSION` and `VIEWER_PORT`:

```bash
# Account A
git clone <repo> ~/chatgpt-export-A && cd ~/chatgpt-export-A && bash setup.sh 65
printf '%s' 'eyJ...A' > token.txt
EXPORT_SESSION=cgpt-A bash restart.sh 65 65
VIEWER_PORT=8765 node viewer/server.js &

# Account B (fresh small -> probe 15 s)
git clone <repo> ~/chatgpt-export-B && cd ~/chatgpt-export-B && bash setup.sh 15
printf '%s' 'eyJ...B' > token.txt
EXPORT_SESSION=cgpt-B bash restart.sh 15 15
VIEWER_PORT=8766 node viewer/server.js &
```
The folders are isolated (their own `out/`, `pw/userdata`, state). **Never run two runners
over the same folder.**

## Troubleshooting
| Symptom | Cause | Fix |
|---|---|---|
| `BX_AUTH_FAIL` / 401 / 403 despite a token | bad/expired token or the profile did not pass CF | paste a fresh token; if needed, log in to the account once in the `pw/userdata` profile |
| lots of `429` / zero progress | rate-limit lockout | cooldown 30–60 min (`.cooldown-until`), 90 s, possibly a new token |
| `HTTP 404/422` on attachments near the end | expired assets on the OpenAI side | normal, they get skipped |
| export "finished" but little data | false done | treat as a lockout (see RATE-LIMITS.md) |
| two runners / corrupted index | two concurrent runners | keep one, if needed reset the indexing flags and re-index |
