# AGENTS.md — operational guide for AI agents

This repo is a **wrapper toolkit** around the upstream exporter
[`brianjlacy/export-chatgpt`](https://github.com/brianjlacy/export-chatgpt)
(cloned by `setup.sh` into `tool/` at pinned commit `4cfc3f2`, never edited).
It downloads **all** ChatGPT conversations + projects (with attachments) of
one account into `out/`, surviving Cloudflare's managed challenge and
aggressive per-account rate limits. One folder = one account.

Detailed docs (`docs/`, `prompts/`, `README.sk.md`) are written in **Slovak**;
this file is the English summary an agent needs to operate the toolkit.

## Golden rules (violating these corrupts data or locks out the account)

1. **NEVER pass `--update`** to the upstream tool — it would overwrite already
   downloaded data. The export is append/resume only.
2. **ONLY ONE runner per folder.** Two concurrent runners share `pw/userdata`
   and `out/` and corrupt the export index.
3. **Change the pace ONLY via `restart.sh <throttle> <min>`** — never by
   editing scripts. The runner reads `.throttle`/`.min-throttle` at startup.
4. **Never edit `run.sh` while it is running** (bash re-reads the file at a
   shifted offset and executes the wrong code).
5. Token goes into `token.txt` (chmod 600) or env `CHATGPT_BEARER_TOKEN` —
   **never** as a CLI argument (it would leak into `ps`).
6. Respect `.cooldown-until` (epoch): if the runner is down and `now < value`,
   **do not restart** — a lockout is cooling down.
7. Work only inside this folder. Never touch files outside it.

## How it runs

```
run.sh                      # infinite supervisor, meant to live in tmux ($EXPORT_SESSION, default "cgpt")
  └─ xvfb-run node pw/browser-export.js
       ├─ real Chromium (Playwright, persistent profile pw/userdata) passes Cloudflare
       ├─ globalThis.fetch rewritten: chatgpt.com → in-page fetch (cf_clearance + Chrome TLS),
       │  other hosts (signed CDN URLs) → native fetch
       └─ runs upstream tool/lib/cli.js main() with:
          --non-interactive --include-archived --throttle <.throttle> --output out/ --account-id <from JWT>
```

Exit handling by `run.sh`: `exit 0` → done ("HOTOVO"); auth failure
(`BX_AUTH_FAIL`) → block and poll `token.txt` every 30 s; `429`/other error →
sleep 5 min and retry.

## Standard operating procedure

```bash
bash setup.sh 65                         # bootstrap: clone upstream, install Playwright+Chromium, state files
printf '%s' 'eyJ...' > token.txt         # accessToken from https://chatgpt.com/api/auth/session (logged in)
EXPORT_SESSION=cgpt bash restart.sh 65 65   # clean start at 65 s/request
bash status.sh                           # counts: downloaded vs index
bash stepdown-controller.sh              # prints STATE + DECISION (SET_65 | SET_90 | STAY)
bash verify.sh                           # content validation (valid JSON, messages present, assets not HTML)
node pw/lockout-test.js <conversation-id>   # one-shot: has a lockout lifted? (exit 0 = yes)
EXPORT_SESSION=<s> bash wait-and-start.sh   # token gate; prints STATUS=NO_TOKEN|BAD_TOKEN|ALREADY_RUNNING|STARTED
```

Monitoring-loop templates (for cron/AI agents) are in `prompts/monitoring-loop.md`
and `prompts/token-wait-loop.md`; the loop logic reference is
`docs/MONITORING-LOOP.md`.

## Rate-limit model (empirical)

- Account ≈ token bucket of **~250 requests**, refill **~1/min**.
- Sustainable pace: **65 s/request** (target/floor). Trouble ceiling: **90 s**.
- Fresh small account: **15 s probe** allowed, but on the **first `429` switch
  to 65 s** (`restart.sh 65 65`).
- Hard lockout (every request 429, zero progress even at 90 s): stop the
  runner, set `.throttle`/`.min-throttle` to 90, set `.cooldown-until = now+3600`,
  wait it out. A **fresh token (re-login) unlocks a hard lockout faster**, but
  the +1/min refill still applies.
- `HTTP 404/422` on attachments near the end = assets expired on OpenAI's
  side. Normal, skipped, **not** an error or a 429.

## "Done" detection (avoid false positives)

Treat the export as complete only when **all** hold:
1. log contains `Export Complete` / `HOTOVO`, and
2. the runner exited with code 0, and
3. downloaded count ≈ index count (`status.sh`: "Konverzácie stiahnuté" vs
   "Konverzácie v hlavnom indexe").

Then run `verify.sh` and ZIP `out/`. `exit 0` with far fewer files than the
index is a **false done** — treat it like a lockout.

## State files (repo root)

| File | Meaning |
|---|---|
| `.throttle` / `.min-throttle` | current pace (s/request), read at runner startup |
| `.cooldown-until` | epoch until which restarts are forbidden (post-lockout) |
| `.stable-count` / `.last-count` | controller memory: clean checks / last conversation count |
| `.last-probe` | epoch of the last 15 s probe |
| `.wait-count` | token-wait attempt counter |
| `.runner-state` | last pace set by `restart.sh` |
| `token.txt` | Bearer token (eyJ...), gitignored, chmod 600 |
| `export.log` | full runner log (`====== RESTART` lines delimit runs) |
| `out/<user-id>/` | the export: `json/`, markdown, `files/`, `projects/`, indexes |

## Slovak log-string glossary

| String in logs/scripts | Meaning |
|---|---|
| `HOTOVO` | done / export complete |
| `POTREBUJEM NOVÝ TOKEN` | need a fresh Bearer token in `token.txt` |
| `overenie OK — prihlásený ako <email>` | auth check OK — logged in as `<email>` |
| `Konverzácie stiahnuté` / `v hlavnom indexe` | conversations downloaded / in main index |
| `Cloudflare výzva` | Cloudflare challenge encountered (auto-retries) |
| `Príčina: vypršaný / neplatný token` | cause: expired/invalid token |
| `pokus` | attempt |

## Gotchas

- `BX_AUTH_FAIL` can also mean the Chromium profile never passed Cloudflare —
  if a fresh token still fails, log into the account once inside the
  `pw/userdata` profile.
- The upstream tool misreports a Cloudflare 403 as "expired token"; the
  wrapper converts persistent challenges to `503` (transient) on purpose.
- `restart.sh` kills only processes belonging to **this folder** (matched by
  `pw/userdata` path in `/proc/*/cmdline`) — safe on multi-account hosts.
- The viewer (`viewer/server.js`, port `VIEWER_PORT`, default 8765) is
  read-only over `out/` but binds `0.0.0.0` — only run it on trusted networks.
