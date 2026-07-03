#!/usr/bin/env bash
# wait-and-start.sh — checks token.txt; if it holds a valid Bearer (eyJ...), starts
# the export in tmux session "$EXPORT_SESSION" (default "cgpt"). Prints ONE status word on the last line:
#   NO_TOKEN        — token.txt empty
#   BAD_TOKEN       — non-empty, but does not look like a JWT
#   ALREADY_RUNNING — export already running
#   STARTED         — export just started
# The account (account-id/plan) is extracted from the JWT and printed so you can confirm it is the right account.
# Run as:  EXPORT_SESSION=<session> bash wait-and-start.sh
set -uo pipefail
J="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION="${EXPORT_SESSION:-cgpt}"
TOKEN_FILE="$J/token.txt"

tok="$(tr -d '\r\n' < "$TOKEN_FILE" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^[Bb]earer[[:space:]]*//')"

if [ -z "$tok" ]; then echo "STATUS=NO_TOKEN"; exit 0; fi
case "$tok" in
  eyJ*) : ;;
  *) echo "STATUS=BAD_TOKEN (does not start with 'eyJ' — does not look like a JWT)"; exit 0 ;;
esac

# Account diagnostics from the JWT
node -e '
  try { const t=process.argv[1]; const p=JSON.parse(Buffer.from(t.split(".")[1],"base64url").toString("utf8"));
    const a=p["https://api.openai.com/auth"]||{};
    console.log("ACCOUNT_ID="+(a.chatgpt_account_id||"?"));
    console.log("PLAN="+(a.chatgpt_plan_type||"?"));
    if(p.exp) console.log("TOKEN_EXP="+new Date(p.exp*1000).toISOString());
  } catch(e){ console.log("ACCOUNT_ID=? (could not read the JWT)"); }
' "$tok" 2>/dev/null

# Is the export already running?
if tmux has-session -t "$SESSION" 2>/dev/null; then echo "STATUS=ALREADY_RUNNING"; exit 0; fi

# Start with a clean restart at the target pace of 65s
bash "$J/restart.sh" 65 65 >/dev/null 2>&1
echo 0 > "$J/.stable-count"
sleep 1
if tmux has-session -t "$SESSION" 2>/dev/null; then echo "STATUS=STARTED"; else echo "STATUS=START_FAILED"; fi
