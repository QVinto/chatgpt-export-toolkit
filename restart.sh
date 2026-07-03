#!/usr/bin/env bash
# restart.sh <throttle> <min_throttle> — CLEAN restart of the SINGLE runner at a given pace.
# Encapsulates the whole procedure: write the pace into state files, kill tmux+chromium+xvfb,
# clear the lock, restart run.sh in tmux "cgpt". browser-export.js reads the throttle
# from the .throttle and .min-throttle files.
set -uo pipefail
THROTTLE="${1:-60}"
MINTH="${2:-$THROTTLE}"
# base-dir = location of this script; its own tmux session (separate from the host project)
EXPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION="${EXPORT_SESSION:-cgpt}"
LOG="$EXPORT_DIR/export.log"
MYPID=$$

# 1) write the pace (browser-export.js reads it at startup)
echo "$THROTTLE" > "$EXPORT_DIR/.throttle"
echo "$MINTH"    > "$EXPORT_DIR/.min-throttle"
echo "THROTTLE=$THROTTLE" > "$EXPORT_DIR/.runner-state"
# if this is a probe (15s), record the probe time
if [ "$THROTTLE" = "15" ]; then date +%s > "$EXPORT_DIR/.last-probe"; fi

# 2) kill the tmux session (kills the run.sh + xvfb-run + node + chromium tree)
tmux kill-session -t "$SESSION" 2>/dev/null
sleep 2
# 3) finish off orphaned chromium/xvfb — ONLY processes from THIS folder (not the host project), NOT the shell
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

# 4) run.sh cosmetics (log header only)
sed -i -E "s/^THROTTLE=[0-9]+$/THROTTLE=$THROTTLE/" "$EXPORT_DIR/run.sh" 2>/dev/null || true

# 5) restart
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ====== RESTART: throttle ${THROTTLE}s (min ${MINTH}s) [restart.sh] ======" >> "$LOG"
tmux new-session -d -s "$SESSION" "bash -lc '$EXPORT_DIR/run.sh; echo; echo \"=== run.sh finished ===\"; exec bash'"
sleep 3
if tmux ls 2>/dev/null | grep -q "$SESSION"; then
  echo "restart.sh: OK — tmux $SESSION running, throttle=${THROTTLE}s"
else
  echo "restart.sh: ERROR — tmux $SESSION did not come up!"
  exit 1
fi
