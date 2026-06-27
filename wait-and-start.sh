#!/usr/bin/env bash
# wait-and-start.sh — skontroluje token.txt; ak je platný Bearer (eyJ...), spustí
# export v tmux session "$EXPORT_SESSION" (default "cgpt"). Vypíše JEDNO stavové slovo na poslednom riadku:
#   NO_TOKEN        — token.txt prázdny
#   BAD_TOKEN       — neprázdny, ale nevyzerá ako JWT
#   ALREADY_RUNNING — export už beží
#   STARTED         — práve som spustil export
# Účet (account-id/plán) sa vytiahne z JWT a vypíše pre kontrolu, že ide o správny účet.
# Spúšťaj ako:  EXPORT_SESSION=<session> bash wait-and-start.sh
set -uo pipefail
J="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION="${EXPORT_SESSION:-cgpt}"
TOKEN_FILE="$J/token.txt"

tok="$(tr -d '\r\n' < "$TOKEN_FILE" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^[Bb]earer[[:space:]]*//')"

if [ -z "$tok" ]; then echo "STATUS=NO_TOKEN"; exit 0; fi
case "$tok" in
  eyJ*) : ;;
  *) echo "STATUS=BAD_TOKEN (nezačína 'eyJ' — nevyzerá ako JWT)"; exit 0 ;;
esac

# Diagnostika účtu z JWT
node -e '
  try { const t=process.argv[1]; const p=JSON.parse(Buffer.from(t.split(".")[1],"base64url").toString("utf8"));
    const a=p["https://api.openai.com/auth"]||{};
    console.log("ACCOUNT_ID="+(a.chatgpt_account_id||"?"));
    console.log("PLAN="+(a.chatgpt_plan_type||"?"));
    if(p.exp) console.log("TOKEN_EXP="+new Date(p.exp*1000).toISOString());
  } catch(e){ console.log("ACCOUNT_ID=? (JWT sa nepodarilo načítať)"); }
' "$tok" 2>/dev/null

# Beží už export?
if tmux has-session -t "$SESSION" 2>/dev/null; then echo "STATUS=ALREADY_RUNNING"; exit 0; fi

# Spusti čistým reštartom na cieľové tempo 65s
bash "$J/restart.sh" 65 65 >/dev/null 2>&1
echo 0 > "$J/.stable-count"
sleep 1
if tmux has-session -t "$SESSION" 2>/dev/null; then echo "STATUS=STARTED"; else echo "STATUS=START_FAILED"; fi
