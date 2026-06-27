# Monitoring loop — prompt (šablóna)

Toto je prompt pre **AI agenta** (napr. Claude Code) spúšťaný cronom/schedulerom v intervale
podľa fázy (30 min stabilný beh; 1–5 min probe/koniec/cooldown). Pred použitím nahraď
placeholdery:

- `<DIR>` → absolútna cesta pracovného priečinka (napr. `~/chatgpt-export-mojucet`)
- `<SESSION>` → názov tmux session (napr. `cgpt` alebo `cgpt-mojucet`)

> Probe variant (15 s → 65 s pri prvom 429) je v sekcii **KROK B** nižšie zahrnutý; pre
> štandardný beh na 65 s sa použije vetva so `stepdown-controller.sh`.

---

```
Monitoring + STEP controller ChatGPT exportu (priečinok <DIR>, tmux "<SESSION>", Playwright browser-export.js). Tempo: cieľ/dno 65s, strop 90s (controller riadi); voliteľný probe 15s -> pri prvom 429 prepni na 65s. Throttle mení LEN <DIR>/restart.sh. NIKDY needituj run.sh počas behu, NIKDY dvaja bežci, NIKDY --update.

KROK 0 — COOLDOWN gate: now=$(date +%s); cool=$(cat <DIR>/.cooldown-until 2>/dev/null||echo 0); node beží? (/proc/*/comm==MainThread s cmdline obsahujúcim <DIR>/pw/browser-export). Ak node NEbeží a now<cool -> reportuj "cooldown do $(date -d @$cool +%H:%M)", KONIEC. Ak node NEbeží a now>=cool -> over token.txt neprázdny; reštart bash <DIR>/restart.sh "$(cat <DIR>/.throttle)" "$(cat <DIR>/.min-throttle)". Ak node beží -> A.

KROK A — health: tmux ls|grep <SESSION>; <DIR>/status.sh; nové 429/"max retries" od posledného "====== RESTART" v <DIR>/export.log. Ak treba token (BX_AUTH_FAIL/Token expired/prázdny a node NEbeží) -> VÝRAZNE vypíš, nech vloží Bearer do <DIR>/token.txt. POZNÁMKA: čerstvý token odomkne tvrdý lockout, ale +1/min refill platí ďalej.

KROK A2 — LOCKOUT (poistka): ak BEŽÍ ale NULOVÝ postup 2 kontroly po sebe A veľa 429/"max retries" -> zastav bežca (kill tmux <SESSION> + chromium s <DIR>/pw/userdata + príslušné xvfb, rm <DIR>/pw/userdata/Singleton*), echo 90><DIR>/.throttle, echo 90><DIR>/.min-throttle, echo $(( $(date +%s)+3600 ))><DIR>/.cooldown-until, reportuj a navrhni čerstvý token. NEREŠTARTUJ.

KROK 5 — HOTOVO len ak v logu "HOTOVO"/Export Complete A node exit 0 A stiahnutých > 0 a počet ≈ "Konverzácie v hlavnom indexe" zo status.sh. Ak exit 0 ale stiahnutých << index (chyby) -> FALOŠNÉ, rieš ako A2. Ak naozaj: <DIR>/verify.sh; ak OK -> ZIP <DIR>/chatgpt-export-$(date +%F).zip z out/, súhrn, UKONČI loop (zruš tento cron + notifikácia). KONIEC.

KROK B — TEMPO: th=$(cat <DIR>/.throttle); n429 = počet nových "Rate limited|max retries" od posledného "====== RESTART".
  - Ak th=15 A n429>=1 -> PRVÝ 429 v probe: bash <DIR>/restart.sh 65 65; over 1 bežca; echo 0 > <DIR>/.stable-count; report "prvý 429 pri 15s -> prepol som na 65s".
  - Ak th=15 A n429=0 -> STAY (ťažíme bucket na 15s).
  - Ak th!=15 -> bash <DIR>/stepdown-controller.sh; podľa DECISION: SET_65->restart.sh 65 65; SET_90->restart.sh 90 90; SET_60->restart.sh 60 60; SET_30->restart.sh 30 30; STAY->nič. (Po reštarte over 1 bežca + echo 0 > <DIR>/.stable-count.)

KROK C — report SK: stav, počet stiahnutých, throttle (cat <DIR>/.throttle), 429, čo si spravil (STAY/prepnutie/cooldown). Jeden cron.
```
