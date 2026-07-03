# Rate-limit: model, tuning and lessons learned

## Limit model (empirical)
An account has a **token-bucket of ~250 requests** + a refill of **~1 request/min** at the account level.
- At a pace of **< 60 s/request** the bucket gradually drains → `429`s start.
- **Sustainable pace ≈ 1 request/min** → target **65 s** (slightly below the refill, builds a small reserve).
- A large account (thousands of conversations) → the export takes **on the order of 1–2 days**.

## Target pace: 65 s
`65 s` is the default. `61 s` is only ~5 % faster, but leaves a 1 s reserve instead of 5 s →
more prone to a slow drift into the negative. **65 s = sweet spot.**

## 15 s "probe" for a fresh small account
An untouched account has a **full bucket of ~250**. If it has fewer than ~250 conversations, it pays off
to start at **15 s** and "drain" the bucket — almost the entire account is pulled before the first
`429` arrives. **Rule: on the FIRST `429`, switch to 65 s.** (Verified: an account with 233 conversations
was pulled in full at 15 s **without a single 429**, in ~1 h instead of ~3.5 h.)

> Do NOT use the probe on a large/already-exhausted account — sub-60 s bursts there trigger a hard lockout.

## Lockout (hard) and recovery
After an aggressive burst, ChatGPT imposes a **hard lockout**: every request returns `429` with a growing
retry (60→300 s), zero progress, even at 90 s. Recovery:
1. **Stop the runner** and hold a **cooldown of ~30–60 min WITH no requests** (`.cooldown-until` epoch;
   the monitoring loop respects it — it does not restart during that time).
2. Resume at **90 s** (consumption 0.67/min < refill 1/min → the buffer replenishes even while running).
3. **A fresh token (re-login) UNLOCKS a hard lockout** faster than a cooldown — it establishes a new
   connection and clears the stuck state. BUT: the token does NOT grant a full buffer; **the base refill of +1/min
   still applies**, so right after a new token you only get ~(elapsed time × 1/min) conversations.

## Adaptive pace (stepdown-controller.sh)
Ladder: **65 s (target/floor) → 90 s (ceiling on 429)**. On each check the controller prints
`DECISION`:
- `STAY` — no change (65 s is the target and it runs clean).
- `SET_90` — `429`s appeared (trouble) → slow down.
- `SET_65` — after `STABLE_NEEDED` (default 3) clean checks → speed back up to the target.

The "trouble" logic: `≥2` new `429`s since the last restart, or (no progress + `≥1` 429).
The pace is changed **exclusively via `restart.sh <throttle> <min>`** (kill + cleanup + restart of a single
runner), never by editing JS.

## Error disambiguation (important)
- `Rate limited` / `max retries` → **429** (address with pace/cooldown).
- `HTTP 404 / 422` on attachments at the tail end → **expired/deleted assets** on OpenAI's side,
  they cannot be downloaded. **This is NOT an error nor a 429** — the tool skips them and continues.
- `BX_AUTH_FAIL` / `Token expired` → **expired token**, put a new one into `token.txt`.

## False "DONE"
Upstream can finish with `exit 0` even when it downloaded little due to errors. That is why the monitoring
considers the export complete only if: the log contains `Export Complete`/`DONE`, `exit 0`, **and** the number
downloaded ≈ the count in the main index (`status.sh`). Otherwise, treat it as a lockout/error.
