# Automated monitoring — the "loop"

An export runs for **hours to days**. Manual patrolling is unsustainable and error-prone. The
solution is the **loop**: a periodic automatic check that manages the pace itself, handles
problems, and wraps everything up once it finishes. The loop can be:

- an **AI agent** (e.g. Claude Code) with a scheduled/cron prompt — recommended, because it can
  interpret the log and make decisions (this is the reference deployment; templates in [`../prompts/`](../prompts/)),
- or a **system cron / `watch`** that runs the decision logic through scripts.

> **Always use the loop.** Without it you will miss token expiry, a 429 storm, or a lockout, and
> the export will either stall or slow down needlessly. The loop = the eyes and hands of the process.

## Check interval (adapt per phase)
| Phase | Interval | Why |
|---|---|---|
| Waiting for token | **~5 h** (max 10 attempts) | the token isn't there yet, no need to check often |
| Normal/stable run at 65 s | **30 min** | it runs clean, occasional checks suffice |
| Probe at 15 s / critical phase / near the end | **1–5 min** | catch the first 429 and switch right away |
| After lockout (cooldown) | **5 min** | wait for the cooldown to elapse |

Change the interval according to the situation — that is part of "automatic adaptation".

## What the loop does (steps)
The reference prompt (`prompts/monitoring-loop.md`) performs:

- **STEP 0 — cooldown gate:** if the runner is not running and `now < .cooldown-until` → do not
  restart, just report "cooldown until HH:MM". If it is not running and the cooldown has expired →
  restart. If it is running → continue.
- **STEP A — health:** is the node alive? (`/proc/*/comm == MainThread` with `…/pw/browser-export`),
  `status.sh`, count of new `429`/`max retries` since the last `====== RESTART`. Is a token needed?
  (`BX_AUTH_FAIL`/`Token expired`/empty + node not running) → print the prompt **prominently**.
- **STEP A2 — lockout (safeguard):** running, but 2 checks with zero progress + many `429` → stop,
  set 90 s, `.cooldown-until = now+3600`, suggest a fresh token. Do NOT restart.
- **STEP 5 — done:** `Export Complete`/`DONE` + `exit 0` + downloaded ≈ index →
  `verify.sh` → ZIP `…-<date>.zip` from `out/` → summary → **end the loop** (remove the cron + notify).
  (Otherwise a false done → handle it like A2.)
- **STEP B — pace (automatic adaptation):** `stepdown-controller.sh` → based on `DECISION`
  call `restart.sh <N> <N>` (or nothing on `STAY`). In probe mode additionally: if `throttle=15`
  and a `429` appeared → `restart.sh 65 65` (first 429 → slow down to the target).
- **STEP C — report:** status, number downloaded, throttle, `DECISION`/cooldown, `429`.

## Two phases = two prompts
1. **Waiting for token** (`prompts/token-wait-loop.md`): ~5 h, max 10 attempts. Runs
   `wait-and-start.sh`; once the token is supplied → it starts the export and **switches** to the monitoring prompt.
2. **Run monitoring** (`prompts/monitoring-loop.md`): the steps above, interval per phase.

## Automatic time adaptation — summary
- **request pace:** `stepdown-controller.sh` 65 ↔ 90 s; probe 15 s → 65 s on the first 429.
- **check interval:** 5 h (waiting) → 30 min (stable run) → 1–5 min (probe/end) →
  5 min (cooldown).
- **cooldown:** `.cooldown-until` after a lockout (30–60 min without requests).

Everything is driven by state files, so the loop is stateless with respect to restarts and can
"read back" at any time where the process is.
