# Architecture

## Problem
The ChatGPT `backend-api` sits behind a Cloudflare **"managed challenge"** (`cf-mitigated: challenge`).
A plain `fetch`/`curl` (even with a valid token) gets a **403** with an HTML challenge page.
The upstream tool mistakenly reports this as an "expired token", even though the token is fine.

## Solution: browser-routed fetch
`pw/browser-export.js` launches a **real Chromium** (Playwright) under `xvfb` (headful), which
passes the Cloudflare challenge automatically and obtains the `cf_clearance` cookie. It then **overrides
`globalThis.fetch`**:

- **host `chatgpt.com`** → the fetch runs **inside the page** (`page.evaluate(fetch …)`),
  i.e. same-origin with `cf_clearance` + a genuine Chrome TLS fingerprint. The body is transferred
  as base64 (works for both text and binary) and wrapped into a `Response`-like object.
- **other host** (signed CDN download URL for attachments) → **native** `fetch` (no challenge).

Afterwards `require(tool/lib/cli.js).main()` kicks off the **unchanged** upstream export — its entire
logic (pagination, projects, markdown, files, resume) works; only the transport layer changes.

If the challenge persists, the page is reloaded (up to 5×); if it still doesn't pass, a
`503` is returned (transient error → retry), **not** an auth-fail (so it won't needlessly ask for a new token).

## Components

```
run.sh  (tmux "cgpt", infinite loop)
  │  read token.txt -> CHATGPT_BEARER_TOKEN (env), account-id from JWT
  └─ xvfb-run -a node pw/browser-export.js
        │  launchPersistentContext(pw/userdata)  -> goto chatgpt.com (passes CF)
        │  auth check /backend-api/me  -> log "logged in as <email>"
        │  globalThis.fetch = browserFetch
        └─ main() from tool/lib/cli.js  (argv: --non-interactive --include-archived
                                       --throttle <.throttle> --output out/ --account-id <jwt>)
  exit 0 -> "DONE"; 429 -> wait 5m; auth-fail -> wait for a new token; other -> wait 5m
```

- **`browser-export.js`** reads `EXPORT_DIR` from `path.resolve(__dirname, '..')` → the folder is
  portable (works for any folder name / multiple accounts).
- **Throttle** is NOT read from the code, but from the `.throttle` file (+`.min-throttle`) → the pace can be
  changed between restarts without editing JS.
- **Account-id** is pulled from the JWT (`chatgpt_account_id`) → works for Business/Team too.
  Note: in a Team workspace the account-id is shared; the **Bearer token (user `sub`)** determines whose
  conversations get downloaded, and the output goes to `out/<user-id>/` (per-user isolated).

## Output
```
out/<user-id>/
  json/        *.json   (raw conversations)
  *.md /markdown/        (readable markdown)
  files/                 (attachments/assets of regular conversations)
  projects/<project>/json|files/   (project conversations and their attachments)
  conversation-index.json, projects/project-index.json
  .export-progress.json  (resume state)
```

## State files (in the folder root)
| File | Meaning |
|---|---|
| `.throttle` / `.min-throttle` | current pace (s/request), read by `browser-export.js` |
| `.cooldown-until` | epoch until which NOT to run (after a lockout) |
| `.stable-count` / `.last-count` | controller: how many clean checks / last count |
| `.last-probe` | epoch of the last 15 s probe |
| `.wait-count` | counter of attempts waiting for a token |
| `.runner-state` | last set pace |
