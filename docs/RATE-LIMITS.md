# Rate-limit: model, ladenie a poučenia

## Model limitu (empirický)
Účet má **token-bucket ~250 dopytov** + doplňovanie **~1 dopyt/min** na úrovni účtu.
- Pri tempe **< 60 s/dopyt** sa bucket postupne vyčerpá → začnú `429`.
- **Udržateľné tempo ≈ 1 dopyt/min** → cieľ **65 s** (mierne pod doplňovaním, buduje malú rezervu).
- Veľký účet (tisíce konverzácií) → export trvá **rádovo 1–2 dni**.

## Cieľové tempo: 65 s
`65 s` je default. `61 s` je len ~5 % rýchlejšie, ale necháva 1 s rezervu namiesto 5 s →
náchylnejšie na pomalý drift do mínusu. **65 s = sweet spot.**

## 15 s „probe" pre čerstvý malý účet
Nedotknutý účet má **plný bucket ~250**. Ak má menej než ~250 konverzácií, oplatí sa
spustiť na **15 s** a „vyťažiť" bucket — stiahne sa skoro celý účet skôr, než príde prvý
`429`. **Pravidlo: pri PRVOM `429` prepni na 65 s.** (Overené: účet s 233 konverzáciami sa
celý stiahol na 15 s **bez jediného 429**, za ~1 h namiesto ~3,5 h.)

> Probe NEpoužívaj na veľkom/už vyťaženom účte — sub-60 s nárazy tam spúšťajú tvrdý lockout.

## Lockout (tvrdý) a zotavenie
Po agresívnom nárazi ChatGPT uvalí **tvrdý lockout**: každý request `429` s rastúcim
retry (60→300 s), nulový postup, aj na 90 s. Zotavenie:
1. **Zastav bežca** a drž **cooldown ~30–60 min BEZ requestov** (`.cooldown-until` epoch;
   monitoring loop ho rešpektuje — počas neho nereštartuje).
2. Obnov na **90 s** (spotreba 0,67/min < doplňovanie 1/min → buffer sa obnovuje aj počas behu).
3. **Čerstvý token (re-login) ODOMKNE tvrdý lockout** rýchlejšie než cooldown — nadviaže nové
   spojenie a zruší zaseknutý stav. ALE: token NEDÁ plný buffer; **základný refill +1/min
   platí ďalej**, takže hneď po novom tokene stihneš len ~(uplynulý čas × 1/min) konverzácií.

## Adaptívne tempo (stepdown-controller.sh)
Rebrík: **65 s (cieľ/dno) → 90 s (strop pri 429)**. Controller pri každej kontrole vypíše
`DECISION`:
- `STAY` — bez zmeny (65 s je cieľové a beží čisto).
- `SET_90` — objavili sa `429` (trouble) → spomaľ.
- `SET_65` — po `STABLE_NEEDED` (default 3) čistých kontrolách → zrýchli späť na cieľ.

Logika „trouble": `≥2` nových `429` od posledného reštartu, alebo (žiadny postup + `≥1` 429).
Tempo sa mení **výhradne cez `restart.sh <throttle> <min>`** (kill + cleanup + reštart jediného
bežca), nikdy editom JS.

## Rozlíšenie chýb (dôležité)
- `Rate limited` / `max retries` → **429** (rieš tempom/cooldownom).
- `HTTP 404 / 422` pri prílohách v závere → **expirované/zmazané assety** na strane OpenAI,
  nedajú sa stiahnuť. **NIE je to chyba ani 429** — nástroj ich preskočí a pokračuje.
- `BX_AUTH_FAIL` / `Token expired` → **vypršaný token**, vlož nový do `token.txt`.

## Falošné „HOTOVO"
Upstream môže skončiť `exit 0` aj keď chybami stiahol málo. Preto monitoring považuje export
za hotový len ak: log obsahuje `Export Complete`/`HOTOVO`, `exit 0`, **a** počet stiahnutých
≈ počet v hlavnom indexe (`status.sh`). Inak to rieš ako lockout/chybu.
