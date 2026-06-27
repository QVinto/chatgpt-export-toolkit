#!/usr/bin/env bash
# restart.sh <throttle> <min_throttle> — ČISTÝ reštart JEDINÉHO bežca na zadané tempo.
# Enkapsuluje celý postup: zápis tempa do state súborov, kill tmux+chromium+xvfb,
# vyčistenie zámku, reštart run.sh v tmux "cgpt". Throttle číta browser-export.js
# zo súborov ~/chatgpt-export/.throttle a .min-throttle.
set -uo pipefail
THROTTLE="${1:-60}"
MINTH="${2:-$THROTTLE}"
# base-dir = umiestnenie tohto skriptu; vlastná tmux session (oddelená od hlavného projektu)
EXPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION="${EXPORT_SESSION:-cgpt}"
LOG="$EXPORT_DIR/export.log"
MYPID=$$

# 1) zapíš tempo (browser-export.js si ho prečíta pri štarte)
echo "$THROTTLE" > "$EXPORT_DIR/.throttle"
echo "$MINTH"    > "$EXPORT_DIR/.min-throttle"
echo "THROTTLE=$THROTTLE" > "$EXPORT_DIR/.runner-state"
# ak je to probe (15s), zaznač čas probe
if [ "$THROTTLE" = "15" ]; then date +%s > "$EXPORT_DIR/.last-probe"; fi

# 2) zabi tmux session (zabije run.sh + xvfb-run + node + chromium strom)
tmux kill-session -t "$SESSION" 2>/dev/null
sleep 2
# 3) doraz osirené chromium/xvfb — LEN procesy z TOHTO priečinka (nie hlavný projekt), NIE shell
for d in /proc/[0-9]*; do
  c=$(cat "$d/comm" 2>/dev/null) || continue
  if { [ "$c" = "chrome" ] || [ "$c" = "MainThread" ] || [ "$c" = "Xvfb" ]; } \
     && grep -qa "$EXPORT_DIR/pw/userdata\|$EXPORT_DIR/pw/browser-export" "$d/cmdline" 2>/dev/null; then
    pid=${d#/proc/}
    [ "$pid" = "$MYPID" ] && continue
    [ "$pid" = "$PPID" ] && continue
    kill "$pid" 2>/dev/null
  fi
done
sleep 2
rm -f "$EXPORT_DIR/pw/userdata/Singleton"* 2>/dev/null

# 4) kozmetika run.sh (len log header)
sed -i -E "s/^THROTTLE=[0-9]+$/THROTTLE=$THROTTLE/" "$EXPORT_DIR/run.sh" 2>/dev/null || true

# 5) reštart
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ====== RESTART: throttle ${THROTTLE}s (min ${MINTH}s) [restart.sh] ======" >> "$LOG"
tmux new-session -d -s "$SESSION" "bash -lc '$EXPORT_DIR/run.sh; echo; echo \"=== run.sh skoncil ===\"; exec bash'"
sleep 3
if tmux ls 2>/dev/null | grep -q "$SESSION"; then
  echo "restart.sh: OK — tmux $SESSION beží, throttle=${THROTTLE}s"
else
  echo "restart.sh: CHYBA — tmux $SESSION nenabehol!"
  exit 1
fi
