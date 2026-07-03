# ChatGPT Export Toolkit

Resilient, self-adapting workflow for downloading **all** of your ChatGPT
conversations and projects — attachments included, **Business/Team** plans
supported — even when the `backend-api` sits behind a Cloudflare *managed
challenge* and the account enforces an aggressive rate limit.

Built on top of [`brianjlacy/export-chatgpt`](https://github.com/brianjlacy/export-chatgpt)
(pinned commit `4cfc3f2`, MIT), which this toolkit deliberately does **not**
modify — it only wraps it:

- **Cloudflare bypass** — the tool's HTTP is routed through a real Chromium
  (Playwright + xvfb) that passes the challenge and carries `cf_clearance`
  plus a genuine Chrome TLS fingerprint.
- **Self-adaptive pacing** — a token-bucket throttle controller
  (15 s probe → 65 s target → 90 s ceiling), automatic slow-down on the first
  `429`, cooldown after a lockout.
- **Resilience** — an infinite supervisor loop, recovery from 429s and
  transient errors, waiting for a fresh token on expiry, and protection
  against a false "done".
- **Automated monitoring ("loop")** — periodic checks (cron or an AI agent)
  that manage the pace on their own, handle 429/lockout/token expiry, and
  produce the final ZIP. See [`docs/MONITORING-LOOP.md`](docs/MONITORING-LOOP.md).
- **Content validation** + a **local web viewer** (full-text search, images,
  mobile-friendly).

> ⚠️ Use this only on **your own** data or accounts you are explicitly
> authorized to export. The toolkit exists for personal data portability.

🇸🇰 Slovenská verzia tohto README: [`README.sk.md`](README.sk.md).
Detailed docs in [`docs/`](docs/) are currently in Slovak; AI agents (and
humans in a hurry) get an English operational summary in [`AGENTS.md`](AGENTS.md).

---

## Quick start

```bash
# 1) Make a working copy (one folder = one account)
git clone https://github.com/QVinto/chatgpt-export-toolkit.git chatgpt-export-myaccount
cd chatgpt-export-myaccount

# 2) Bootstrap (clones the upstream tool at a pinned commit, installs
#    Playwright + Chromium, creates state files)
bash setup.sh 65            # 65 = target pace in s/request; for a fresh small account try 15

# 3) Paste your Bearer token (eyJ...) — the raw token only, without "Bearer"
#    From a logged-in chatgpt.com session: https://chatgpt.com/api/auth/session -> "accessToken"
nano token.txt

# 4) Start the runner (inside tmux session "cgpt")
EXPORT_SESSION=cgpt bash restart.sh 65 65

# 5) Watch
bash status.sh
tmux attach -t cgpt        # Ctrl-b d to detach

# 6) (optional) Local web viewer on port 8765
VIEWER_PORT=8765 node viewer/server.js
```

Multiple accounts at once? Clone the repo into several folders and give each
its own `EXPORT_SESSION` and `VIEWER_PORT`. Folders are fully isolated (own
`out/`, `pw/userdata`, state files). A real two-account deployment example is
in [`docs/REPRODUCE.md`](docs/REPRODUCE.md).

---

## How it works (short version)

```
run.sh (supervisor, tmux "cgpt")
  └─ xvfb-run node pw/browser-export.js
        ├─ launches Chromium (Playwright) -> passes Cloudflare
        ├─ rewrites globalThis.fetch: chatgpt.com -> in-page fetch (cf_clearance), CDN -> native
        └─ loads tool/lib/cli.js main() (upstream export, NEVER --update)
restart.sh             clean restart of the runner at a given pace (writes .throttle)
stepdown-controller.sh decides on pace changes (DECISION: SET_65/SET_90/STAY...)
status.sh / verify.sh  counts / content validation
wait-and-start.sh      waits for a token to be pasted, then starts the export
viewer/                local export browser (plain Node, zero dependencies)
```

Details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (Slovak).

---

## Rate limits (why it takes long and how it is tuned)

A ChatGPT account behaves like a token bucket of roughly **250 requests**
refilled at about **1 request/min**, so the sustainable pace is **~60–65 s
per request**. A fresh, untouched account has a full bucket — that is when a
**15 s probe** pays off: if the account has fewer than ~250 conversations,
almost everything downloads before the first `429`; on the first `429` the
controller switches to 65 s. Sub-60 s bursts on a busy account trigger
**multi-hour lockouts**. Full lessons learned: [`docs/RATE-LIMITS.md`](docs/RATE-LIMITS.md) (Slovak).

---

## Automated monitoring ("loop") — RECOMMENDED

An export runs for **hours to days** (rate limit, token expiry). Don't babysit
it manually — deploy a **loop**: a periodic check (cron every 1–30 min, or an
AI agent) that:

1. verifies the runner is alive (and restarts it through the cooldown gate if needed),
2. runs the **stepdown controller** and adjusts the pace per its `DECISION` (`restart.sh`),
3. catches `429`s/lockouts (slow down / cooldown) and token expiry (asks for a new one),
4. after `Export Complete` runs `verify.sh`, builds the ZIP and ends the loop.

Ready-made prompt templates live in [`prompts/`](prompts/), the full guide in
[`docs/MONITORING-LOOP.md`](docs/MONITORING-LOOP.md) (Slovak).

---

## Safety rules (baked into the scripts)

1. Work **strictly** inside your own folder. Never delete/overwrite outside it.
2. **NEVER `--update`** (it would overwrite already downloaded data). The export only adds.
3. The token is passed via an **env variable** (`CHATGPT_BEARER_TOKEN`), never as
   a CLI argument (which would leak into `ps`).
4. **ONLY ONE runner** per folder (shared `pw/userdata` + `out/` → index corruption).
5. **Never edit `run.sh` while it runs** (bash re-reads at a shifted offset → executes garbage).

---

## Repository layout

| Path | Purpose |
|---|---|
| `setup.sh` | bootstrap (upstream tool + Playwright + state files) |
| `run.sh` | resilient supervisor (tmux) |
| `restart.sh` | clean restart at a given pace (the only way to change the throttle) |
| `stepdown-controller.sh` | adaptive pace decision |
| `status.sh` / `verify.sh` | counts / content validation |
| `wait-and-start.sh` | wait for token + start |
| `pw/browser-export.js` | Cloudflare-bypass fetch proxy + upstream launcher |
| `pw/lockout-test.js` | one-shot test whether a rate-limit lockout has lifted |
| `viewer/` | local web viewer (port via `VIEWER_PORT`) |
| `docs/` | architecture, rate limits, monitoring, reproduction (Slovak) |
| `prompts/` | loop prompt templates (monitoring, token wait) |
| `AGENTS.md` | operational cheat-sheet for AI agents (English) |

---

## Credits & license

- Export core: [`brianjlacy/export-chatgpt`](https://github.com/brianjlacy/export-chatgpt)
  (MIT). It is **not vendored** — `setup.sh` clones it at the pinned commit
  `4cfc3f2` into `tool/`, and it keeps its own license.
- This toolkit adds the Cloudflare bypass, adaptive pacing, the monitoring
  loop, content validation and the viewer. Licensed under the [MIT License](LICENSE).
