#!/usr/bin/env bash
# stepdown-controller.sh — adaptive pace on the ladder 90s (safest) <-> 65s (target/floor, fastest allowed).
# DOWN (speed up) when the pace has been stable for N checks; UP (slow down) on 429 trouble.
# Prints DECISION: SET_65 | SET_90 | STAY  (the cron calls restart.sh <N> <N> accordingly).
set -uo pipefail
E="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; LOG="$E/export.log"
STABLE_NEEDED="${STABLE_NEEDED:-3}"   # clean checks (every 5min) before speeding up

mode=$(cat "$E/.throttle" 2>/dev/null || echo 90)
UDIR="$(find "$E/out" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n1)"
cnt=$(find "$UDIR" -type f -path '*/json/*.json' 2>/dev/null | wc -l)
lastcnt=$(cat "$E/.last-count" 2>/dev/null || echo 0)
echo "$cnt" > "$E/.last-count"
progressing=no; [ "$cnt" -gt "$lastcnt" ] && progressing=yes

last=$(grep -an '====== RESTART' "$LOG" 2>/dev/null | tail -n1 | cut -d: -f1); [ -z "$last" ] && last=1
n429=$(tail -n +"$last" "$LOG" 2>/dev/null | tr '\r' '\n' | grep -aicE 'Rate limited|max retries'); [ -z "$n429" ] && n429=0
stable=$(cat "$E/.stable-count" 2>/dev/null || echo 0)

# Ladder: target/floor 65s (slightly below the ~1/min refill → builds a small buffer), ceiling 90s (on a 429 problem).
up()   { echo 90; }
down() { echo 65; }

echo "STATE: throttle=${mode}s | progressing=$progressing ($lastcnt->$cnt) | new_429=$n429 | stable=$stable/$STABLE_NEEDED"

trouble=no
{ [ "$n429" -ge 2 ] || { [ "$progressing" = no ] && [ "$n429" -ge 1 ]; }; } && trouble=yes

if [ "$trouble" = yes ]; then
  echo 0 > "$E/.stable-count"
  t=$(up "$mode")
  if [ "$t" != "$mode" ]; then echo "DECISION: SET_$t"; echo "REASON: ${mode}s has 429 trouble ($n429) → slowing down to ${t}s";
  else echo "DECISION: STAY"; echo "REASON: ${mode}s is already the safest, 429=$n429 (lockout handled by cron A2)"; fi
elif [ "$progressing" = yes ] && [ "$n429" -le 1 ]; then
  stable=$((stable+1)); echo "$stable" > "$E/.stable-count"
  t=$(down "$mode")
  if [ "$stable" -ge "$STABLE_NEEDED" ] && [ "$t" != "$mode" ]; then
    echo 0 > "$E/.stable-count"; echo "DECISION: SET_$t"; echo "REASON: ${mode}s stable ${STABLE_NEEDED}x → speeding up to ${t}s"
  elif [ "$t" = "$mode" ]; then echo "DECISION: STAY"; echo "REASON: ${mode}s is the target (fastest allowed), running clean"
  else echo "DECISION: STAY"; echo "REASON: ${mode}s clean (${stable}/${STABLE_NEEDED} until speeding up to ${t}s)"; fi
else
  echo "DECISION: STAY"; echo "REASON: ${mode}s — no change (progress=$progressing, 429=$n429; e.g. re-walk after a restart)"
fi
