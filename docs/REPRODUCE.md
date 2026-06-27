# Reprodukcia krok za krokom

## Predpoklady
- Linux, **Node.js ≥ 18** (testované na v24), `git`, `tmux`, `xvfb` (`xvfb-run`).
  - Debian/Ubuntu: `sudo apt install -y git tmux xvfb`
- Prístup k cieľovému ChatGPT účtu (vlastnému / s oprávnením).

## 1) Pracovná kópia (jeden priečinok = jeden účet)
```bash
git clone <toto-repo> chatgpt-export-<meno>
cd chatgpt-export-<meno>
bash setup.sh 65        # 65 s cieľ; čerstvý malý účet -> skús 15
```
`setup.sh` naklonuje upstream do `tool/`, nainštaluje Playwright+Chromium do `pw/`,
vytvorí stavové súbory, `out/` a prázdny `token.txt`.

## 2) Token
Prihlás sa do účtu v prehliadači, otvor `https://chatgpt.com/api/auth/session`, skopíruj
hodnotu **`accessToken`** (`eyJ...`) a vlož **len ten reťazec** (bez „Bearer") do `token.txt`:
```bash
printf '%s' 'eyJ...' > token.txt && chmod 600 token.txt
```
Token platí ~niekoľko hodín až dní; pri expirácii loop vypýta nový.

## 3) Spustenie
```bash
EXPORT_SESSION=cgpt bash restart.sh 65 65     # alebo 15 15 pre probe
bash status.sh
tmux attach -t cgpt                            # log naživo; Ctrl-b d = odpojiť
```
V logu over `overenie OK — prihlásený ako <email>` (správny účet).

## 4) Monitoring loop (odporúčané)
Nasadenie loopu (AI agent alebo cron) podľa [`MONITORING-LOOP.md`](MONITORING-LOOP.md) +
šablón v [`../prompts/`](../prompts/). Loop sám rieši tempo, 429, lockout, expiráciu tokenu
a finálny ZIP.

## 5) Dokončenie
Po `Export Complete` (`exit 0`, počet ≈ index):
```bash
bash verify.sh                                  # obsahová validácia
zip -r -1 chatgpt-export-<meno>-$(date +%F).zip out
```

## 6) Prehliadač (voliteľné)
```bash
VIEWER_PORT=8765 node viewer/server.js          # http://localhost:8765 (alebo cez Tailscale)
```

---

## Viac účtov naraz (referenčné nasadenie)
Každý účet = samostatná kópia repa, **iný** `EXPORT_SESSION` a `VIEWER_PORT`:

```bash
# Účet A
git clone <repo> ~/chatgpt-export-A && cd ~/chatgpt-export-A && bash setup.sh 65
printf '%s' 'eyJ...A' > token.txt
EXPORT_SESSION=cgpt-A bash restart.sh 65 65
VIEWER_PORT=8765 node viewer/server.js &

# Účet B (čerstvý malý -> probe 15 s)
git clone <repo> ~/chatgpt-export-B && cd ~/chatgpt-export-B && bash setup.sh 15
printf '%s' 'eyJ...B' > token.txt
EXPORT_SESSION=cgpt-B bash restart.sh 15 15
VIEWER_PORT=8766 node viewer/server.js &
```
Priečinky sú izolované (vlastné `out/`, `pw/userdata`, stav). **Nikdy nespúšťaj dvoch bežcov
nad tým istým priečinkom.**

## Riešenie problémov
| Príznak | Príčina | Riešenie |
|---|---|---|
| `BX_AUTH_FAIL` / 401 / 403 napriek tokenu | zlý/expirovaný token alebo profil neprešiel CF | vlož čerstvý token; ak treba, raz sa prihlás do účtu v `pw/userdata` profile |
| veľa `429` / nulový postup | rate-limit lockout | cooldown 30–60 min (`.cooldown-until`), 90 s, prípadne nový token |
| `HTTP 404/422` na prílohách v závere | expirované assety na strane OpenAI | normálne, preskočí sa |
| export „skončil" ale málo dát | falošné hotovo | rieš ako lockout (viď RATE-LIMITS.md) |
| dva bežce / poškodený index | dvaja súbežní bežci | nechaj jeden, prípadne resetuj indexačné príznaky a re-indexuj |
