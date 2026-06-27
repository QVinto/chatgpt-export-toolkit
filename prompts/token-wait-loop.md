# Token-wait loop — prompt (šablóna)

Prompt pre AI agenta spúšťaný cronom ~každých **5 h**, ktorý čaká, kým používateľ vloží
Bearer token, **max 10 pokusov** (~50 h). Keď je token vložený → spustí export a prepne sa
na monitoring loop (`monitoring-loop.md`). Nahraď placeholdery:

- `<DIR>` → absolútna cesta pracovného priečinka
- `<SESSION>` → názov tmux session
- `<MONITOR_PROMPT>` → celý text z `monitoring-loop.md` (s vyplnenými `<DIR>`/`<SESSION>`)

---

```
TOKEN-WAIT loop — priečinok <DIR>, tmux "<SESSION>". Cieľ: počkať na Bearer token (vloží ho používateľ do <DIR>/token.txt), max 10 pokusov à ~5h, potom spustiť export a prepnúť na monitorovanie. Jeden cron.

KROK 1 — skús spustiť: out=$(bash <DIR>/wait-and-start.sh 2>&1); vypíš celé out (obsahuje ACCOUNT_ID/PLAN/TOKEN_EXP + na poslednom riadku STATUS=...). Pozn.: wait-and-start.sh používa EXPORT_SESSION; spúšťaj ho ako: EXPORT_SESSION=<SESSION> bash <DIR>/wait-and-start.sh

KROK 2 — vyhodnoť STATUS z posledného riadku:

(A) STATUS=STARTED alebo STATUS=ALREADY_RUNNING -> token je platný a export beží:
  1) Over jedného bežca: tmux ls | grep <SESSION>.
  2) Zruš TENTO wait-cron.
  3) Vytvor MONITOROVACÍ cron (interval 30 min, alebo 1-5 min pri probe) s promptom: <MONITOR_PROMPT>.
  4) echo 0 > <DIR>/.wait-count
  5) Report SK (uveď ACCOUNT_ID, že export beží) + notifikácia. Spusti hneď prvú monitorovaciu kontrolu. KONIEC.

(B) STATUS=NO_TOKEN alebo STATUS=BAD_TOKEN -> token ešte nie je (platný):
  1) c=$(( $(cat <DIR>/.wait-count 2>/dev/null||echo 0) + 1 )); echo $c > <DIR>/.wait-count
  2) Ak c -ge 10 -> Report "Po 10 pokusoch (~50h) stále bez platného tokenu, končím čakanie." ; zruš tento cron ; notifikácia. KONIEC.
  3) Inak -> Report "Čakám na token (pokus c/10). Vlož Bearer (eyJ...) do <DIR>/token.txt. Ďalšia kontrola o ~5h." KONIEC.

(C) STATUS=START_FAILED -> reštart zlyhal: report, pozri tmux + tail <DIR>/export.log, NEZvyšuj wait-count, skús pri ďalšom firnutí. KONIEC.
```
