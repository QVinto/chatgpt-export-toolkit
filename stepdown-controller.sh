#!/usr/bin/env bash
# stepdown-controller.sh — adaptívne tempo na rebríku 90(najbezpečnejšie) -> 60 -> 30(najrýchlejšie povolené).
# DOWN (zrýchlenie) keď je tempo stabilné N kontrol; UP (spomalenie) pri 429 problémoch.
# Vypíše DECISION: SET_30 | SET_60 | SET_90 | STAY  (cron podľa toho zavolá restart.sh <N> <N>).
set -uo pipefail
E="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; LOG="$E/export.log"
STABLE_NEEDED="${STABLE_NEEDED:-3}"   # čistých kontrol (à 5min) pred zrýchlením

mode=$(cat "$E/.throttle" 2>/dev/null || echo 90)
UDIR="$(find "$E/out" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n1)"
cnt=$(find "$UDIR" -type f -path '*/json/*.json' 2>/dev/null | wc -l)
lastcnt=$(cat "$E/.last-count" 2>/dev/null || echo 0)
echo "$cnt" > "$E/.last-count"
progressing=no; [ "$cnt" -gt "$lastcnt" ] && progressing=yes

last=$(grep -an '====== RESTART' "$LOG" 2>/dev/null | tail -n1 | cut -d: -f1); [ -z "$last" ] && last=1
n429=$(tail -n +"$last" "$LOG" 2>/dev/null | tr '\r' '\n' | grep -aicE 'Rate limited|max retries'); [ -z "$n429" ] && n429=0
stable=$(cat "$E/.stable-count" 2>/dev/null || echo 0)

# Rebrík: cieľ/dno 65s (mierne pod doplňovaním ~1/min → buduje malú rezervu), strop 90s (pri 429 probléme).
up()   { echo 90; }
down() { echo 65; }

echo "STATE: throttle=${mode}s | progressing=$progressing ($lastcnt->$cnt) | new_429=$n429 | stable=$stable/$STABLE_NEEDED"

trouble=no
{ [ "$n429" -ge 2 ] || { [ "$progressing" = no ] && [ "$n429" -ge 1 ]; }; } && trouble=yes

if [ "$trouble" = yes ]; then
  echo 0 > "$E/.stable-count"
  t=$(up "$mode")
  if [ "$t" != "$mode" ]; then echo "DECISION: SET_$t"; echo "REASON: ${mode}s má 429 problémy ($n429) → spomaľujem na ${t}s";
  else echo "DECISION: STAY"; echo "REASON: ${mode}s je už najbezpečnejšie, 429=$n429 (lockout rieši cron A2)"; fi
elif [ "$progressing" = yes ] && [ "$n429" -le 1 ]; then
  stable=$((stable+1)); echo "$stable" > "$E/.stable-count"
  t=$(down "$mode")
  if [ "$stable" -ge "$STABLE_NEEDED" ] && [ "$t" != "$mode" ]; then
    echo 0 > "$E/.stable-count"; echo "DECISION: SET_$t"; echo "REASON: ${mode}s stabilné ${STABLE_NEEDED}x → zrýchľujem na ${t}s"
  elif [ "$t" = "$mode" ]; then echo "DECISION: STAY"; echo "REASON: ${mode}s je cieľové (najrýchlejšie povolené), beží čisto"
  else echo "DECISION: STAY"; echo "REASON: ${mode}s čisté (${stable}/${STABLE_NEEDED} do zrýchlenia na ${t}s)"; fi
else
  echo "DECISION: STAY"; echo "REASON: ${mode}s — bez zmeny (postup=$progressing, 429=$n429; napr. re-walk po reštarte)"
fi
