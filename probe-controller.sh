#!/usr/bin/env bash
# probe-controller.sh — decides the rate-limit probing strategy (READ-ONLY, never restarts).
# Prints DECISION: PROBE_NOW | REVERT_NOW | STAY_15 | STAY_60
#   PROBE_NOW  -> we are at the safe 60s and ~1h has passed since the last probe => try 15s
#   REVERT_NOW -> we are in a 15s probe and 429s appeared => back to 60s
#   STAY_15    -> the 15s probe runs clean (the limit likely reset) => keep the fast pace
#   STAY_60    -> safe 60s, not yet time for another probe
# The loop (cron/agent) calls restart.sh accordingly and adjusts the cron interval.
set -uo pipefail
# base-dir = location of this script (works for any folder name)
EXPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$EXPORT_DIR/export.log"
PROBE_INTERVAL_MIN="${PROBE_INTERVAL_MIN:-180}"   # how often to probe (min) — 3h, since each probe costs ~12min of restart overhead
REVERT_429_THRESHOLD="${REVERT_429_THRESHOLD:-2}" # how many new 429s during a probe => revert

now=$(date +%s)
mode=$(sed -n 's/^THROTTLE=//p' "$EXPORT_DIR/.runner-state" 2>/dev/null | head -n1)
[ -z "$mode" ] && mode=60
last_probe=$(cat "$EXPORT_DIR/.last-probe" 2>/dev/null || echo 0)
[ -z "$last_probe" ] && last_probe=0
mins_since_probe=$(( (now - last_probe) / 60 ))

# Count NEW 429s since the last RESTART marker (any)
n429=$(awk '/====== RESTART:/{buf=""} {buf=buf"\n"$0} END{print buf}' "$LOG" 2>/dev/null \
  | tr '\r' '\n' | grep -aicE 'Rate limited|\b429\b' || echo 0)
# more robust: 429s after the last RESTART line
n429=$(awk '/====== RESTART:/{f=1; c=0; next} f&&/Rate limited|429/{c++} END{print c+0}' <(tr '\r' '\n' < "$LOG") 2>/dev/null)
[ -z "$n429" ] && n429=0

echo "STATE: mode=${mode}s | mins_since_probe=${mins_since_probe} | new_429=${n429} | probe_interval=${PROBE_INTERVAL_MIN}min"

if [ "$mode" = "15" ]; then
  if [ "$n429" -ge "$REVERT_429_THRESHOLD" ]; then
    echo "DECISION: REVERT_NOW"
    echo "REASON: 15s probe hit ${n429} x 429 (>=${REVERT_429_THRESHOLD}) — limit still active, revert to 60s + 10min."
  else
    echo "DECISION: STAY_15"
    echo "REASON: 15s probe running clean (${n429} x 429) — limit likely reset, keep exploiting the fast pace."
  fi
else
  if [ "$mins_since_probe" -ge "$PROBE_INTERVAL_MIN" ]; then
    echo "DECISION: PROBE_NOW"
    echo "REASON: ${mins_since_probe}min since last probe (>=${PROBE_INTERVAL_MIN}) — testing whether the limit reset (15s + 5min)."
  else
    echo "DECISION: STAY_60"
    echo "REASON: safe 60s, next probe in $(( PROBE_INTERVAL_MIN - mins_since_probe ))min."
  fi
fi
