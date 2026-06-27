# Automatické monitorovanie — „loop"

Export beží **hodiny až dni**. Ručné hliadkovanie je neúnosné a chybové. Riešenie je
**loop**: periodická automatická kontrola, ktorá sama riadi tempo, rieši problémy a po
dokončení všetko uzavrie. Loop môže byť:

- **AI agent** (napr. Claude Code) so scheduled/cron promptom — odporúčané, lebo vie
  interpretovať log a rozhodovať (toto je referenčné nasadenie; šablóny v [`../prompts/`](../prompts/)),
- alebo **systémový cron / `watch`**, ktorý spúšťa rozhodovaciu logiku skriptami.

> **Loop používaj vždy.** Bez neho zmeškáš expiráciu tokenu, 429 búrku či lockout a export
> sa buď zasekne, alebo zbytočne spomalí. Loop = oči + ruky procesu.

## Interval (adaptuj podľa fázy)
| Fáza | Interval | Prečo |
|---|---|---|
| Čakanie na token | **~5 h** (max 10 pokusov) | token ešte nie je, netreba často |
| Bežný/stabilný beh na 65 s | **30 min** | beží čisto, stačí občas |
| Probe na 15 s / kritická fáza / blízko konca | **1–5 min** | chytiť prvý 429 a hneď prepnúť |
| Po lockoute (cooldown) | **5 min** | čakať na uplynutie cooldownu |

Interval meň podľa situácie — to je súčasť „automatickej adaptácie".

## Čo loop robí (kroky)
Referenčný prompt (`prompts/monitoring-loop.md`) vykonáva:

- **KROK 0 — cooldown gate:** ak bežec nebeží a `now < .cooldown-until` → nereštartuj, len
  reportuj „cooldown do HH:MM". Ak nebeží a cooldown vypršal → reštartni. Ak beží → ďalej.
- **KROK A — health:** žije node? (`/proc/*/comm == MainThread` s `…/pw/browser-export`),
  `status.sh`, počet nových `429`/`max retries` od posledného `====== RESTART`. Treba token?
  (`BX_AUTH_FAIL`/`Token expired`/prázdny + node nebeží) → **výrazne** vypíš výzvu.
- **KROK A2 — lockout (poistka):** beží, ale 2 kontroly nulový postup + veľa `429` → zastav,
  nastav 90 s, `.cooldown-until = now+3600`, navrhni čerstvý token. NEreštartuj.
- **KROK 5 — hotovo:** `Export Complete`/`HOTOVO` + `exit 0` + stiahnutých ≈ index →
  `verify.sh` → ZIP `…-<dátum>.zip` z `out/` → súhrn → **ukonči loop** (zruš cron + notifikuj).
  (Inak falošné hotovo → rieš ako A2.)
- **KROK B — tempo (automatická adaptácia):** `stepdown-controller.sh` → podľa `DECISION`
  zavolaj `restart.sh <N> <N>` (alebo nič pri `STAY`). V probe režime navyše: ak `throttle=15`
  a pribudol `429` → `restart.sh 65 65` (prvý 429 → spomaľ na cieľ).
- **KROK C — report:** stav, počet stiahnutých, throttle, `DECISION`/cooldown, `429`.

## Dve fázy = dva prompty
1. **Čakanie na token** (`prompts/token-wait-loop.md`): ~5 h, max 10 pokusov. Spustí
   `wait-and-start.sh`; keď je token vložený → spustí export a **prepne sa** na monitoring prompt.
2. **Monitoring behu** (`prompts/monitoring-loop.md`): kroky vyššie, interval podľa fázy.

## Automatická adaptácia časov — zhrnutie
- **tempo dopytov:** `stepdown-controller.sh` 65 ↔ 90 s; probe 15 s → 65 s pri prvom 429.
- **interval kontrol:** 5 h (čakanie) → 30 min (stabilný beh) → 1–5 min (probe/koniec) →
  5 min (cooldown).
- **cooldown:** `.cooldown-until` po lockoute (30–60 min bez requestov).

Všetko je riadené stavovými súbormi, takže loop je bezstavový voči reštartom a vie sa
kedykoľvek „dočítať", kde proces je.
