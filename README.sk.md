# ChatGPT Export Toolkit (odolný, samo-adaptívny)

> 🇬🇧 English version: [`README.md`](README.md) · AI-agent guide: [`AGENTS.md`](AGENTS.md)
>
> Pozn.: kód, logy a podrobná dokumentácia v [`docs/`](docs/) sú po anglicky
> (toto SK README je len prehľad). Slovenské log hlášky boli nahradené anglickými.

Kompletný, **reprodukovateľný** workflow na stiahnutie **všetkých** ChatGPT konverzácií
+ projektov (vrátane príloh) z účtu — vrátane **Business/Team** — aj keď je `backend-api`
za Cloudflare „managed challenge" a účet má agresívny rate-limit.

Postavené nad [`brianjlacy/export-chatgpt`](https://github.com/brianjlacy/export-chatgpt)
(commit `4cfc3f2`), ktorý **needitujeme** — len obaľujeme:

- **Cloudflare bypass** — HTTP nástroja prepošleme cez reálny Chromium (Playwright/xvfb),
  ktorý prejde challenge a má `cf_clearance` + Chrome TLS.
- **Samo-adaptívne tempo** — token-bucket throttle controller (15 s probe → 65 s cieľ →
  90 s strop), automatické spomalenie pri prvom `429`, cooldown pri lockoute.
- **Odolnosť** — nekonečný supervisor, zotavenie z 429/chýb, čakanie na nový token pri
  expirácii, ochrana proti falošnému „hotovo".
- **Automatické monitorovanie cez „loop"** — periodické kontroly (cron/agent) ktoré samy
  riadia tempo, riešia 429/lockout/expiráciu tokenu a po dokončení spravia ZIP. Viď
  [`docs/MONITORING-LOOP.md`](docs/MONITORING-LOOP.md).
- **Obsahová validácia** + **lokálny webový prehliadač** (hľadanie, obrázky, mobil).

> ⚠️ Používaj len na **vlastné** dáta / účty, na ktoré máš oprávnenie.

---

## Prečo to vzniklo

[`brianjlacy/export-chatgpt`](https://github.com/brianjlacy/export-chatgpt) robí tú
ťažkú prácu — prejde ChatGPT backend API a zapíše na disk každú konverzáciu, projekt
aj prílohu. Samotný však na reálnom, aktívnom účte export nedokončí, a to z dvoch dôvodov:

- ChatGPT `backend-api` je za Cloudflare **„managed challenge"**, takže obyčajný HTTP
  klient (aj s platným tokenom) dostane `403` — čo nástroj mylne hlási ako *„expirovaný
  token"*, hoci token je v poriadku.
- **Business/Team** účty majú agresívny rate-limit na účet. Naivný beh narazí na `429`
  a viachodinové lockouty dávno pred dokončením veľkého exportu.

Tento toolkit vznikol, aby dotiahol túto poslednú míľu **bez zásahu do pôvodného
nástroja**: HTTP nástroja prepošle cez reálny prehliadač (Cloudflare je spokojný),
tempo drží pod rate-limitom a celý beh stráži, takže veľký export sa dokončí sám cez
hodiny až dni. Exportná logika ostáva 100 % upstream — pridaná je len transportná
vrstva a „opatrovanie". Preto `setup.sh` upstream **klonuje** na pinnutý commit (nie
vendoruje ani neforkuje): kredit a aktualizácie ostávajú pri pôvodnom projekte.

---

## Rýchly štart

```bash
# 1) Sprav si pracovnú kópiu (jeden priečinok = jeden účet)
git clone https://github.com/QVinto/chatgpt-export-toolkit.git chatgpt-export-mojucet && cd chatgpt-export-mojucet

# 2) Bootstrap (naklonuje upstream nástroj, nainštaluje Playwright+Chromium, stavové súbory)
bash setup.sh 65            # 65 = cieľové tempo s/dopyt; pre čerstvý malý účet skús 15

# 3) Vlož Bearer token (eyJ...) — len samotný token, bez slova "Bearer"
#    Z prihláseného chatgpt.com: https://chatgpt.com/api/auth/session -> "accessToken"
nano token.txt

# 4) Spusti bežca (v tmux session "cgpt")
EXPORT_SESSION=cgpt bash restart.sh 65 65

# 5) Sleduj
bash status.sh
tmux attach -t cgpt        # Ctrl-b d pre odpojenie

# 6) (voliteľne) Webový prehliadač na porte 8765
VIEWER_PORT=8765 node viewer/server.js
```

Viac účtov naraz? Sklonuj repo do viacerých priečinkov a každému daj **iný**
`EXPORT_SESSION` a `VIEWER_PORT`. Priečinky sú navzájom izolované (vlastné `out/`,
`pw/userdata`, stavové súbory). Príklad reálneho dvoj-účtového nasadenia v
[`docs/REPRODUCE.md`](docs/REPRODUCE.md).

---

## Ako to funguje (stručne)

```
run.sh (supervisor, tmux "cgpt")
  └─ xvfb-run node pw/browser-export.js
        ├─ spustí Chromium (Playwright) -> prejde Cloudflare
        ├─ prepíše globalThis.fetch: chatgpt.com -> in-page fetch (cf_clearance), CDN -> native
        └─ načíta tool/lib/cli.js main() (upstream export, NIKDY --update)
restart.sh            čistý reštart bežca na zadané tempo (mení .throttle)
stepdown-controller.sh rozhodne o zmene tempa (DECISION: SET_65/SET_90/STAY...)
status.sh / verify.sh počty / obsahová validácia
wait-and-start.sh     čaká na vloženie tokenu a spustí export
viewer/               lokálny prehliadač exportu (Node, bez závislostí)
```

Detaily: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## Rate-limit (prečo to trvá a ako to ladíme)

Účet má token-bucket ~**250** dopytov + doplňovanie ~**1/min**. Udržateľné tempo je
preto **~60–65 s/dopyt**. Čerstvý (nedotknutý) účet má plný bucket — vtedy sa oplatí
**15 s probe**: ak je konverzácií < ~250, stiahnu sa skoro celé skôr, než príde prvý
`429`; pri prvom `429` controller prepne na 65 s. Sub-60 s nárazy na vyťaženom účte
spúšťajú **viachodinové lockouty**. Plné poučenia: [`docs/RATE-LIMITS.md`](docs/RATE-LIMITS.md).

---

## Automatické monitorovanie („loop") — ODPORÚČANÉ

Export beží **hodiny až dni** (rate-limit, expirácia tokenu). Nehliadkuj ručne — nasaď
**loop**: periodická kontrola (cron každých 1–30 min, alebo AI agent), ktorá:

1. overí, že bežec žije (a reštartuje cez cooldown gate, ak treba),
2. spustí **stepdown-controller** a podľa `DECISION` upraví tempo (`restart.sh`),
3. zachytí `429`/lockout (spomalí/cooldown) a expiráciu tokenu (vypýta nový),
4. po `Export Complete` spustí `verify.sh`, spraví ZIP a ukončí loop.

Hotové prompty (šablóny) sú v [`prompts/`](prompts/), celý návod v
[`docs/MONITORING-LOOP.md`](docs/MONITORING-LOOP.md).

---

## Bezpečnostné pravidlá (zabudované do skriptov)

1. Pracuj **výhradne** vo vlastnom priečinku. Nikdy nemaž/neprepisuj mimo neho.
2. **NIKDY `--update`** (prepísalo by stiahnuté dáta). Export len pridáva.
3. Token cez **env premennú** (`CHATGPT_BEARER_TOKEN`), nie cez CLI argument (únik do `ps`).
4. **LEN JEDEN bežec** na priečinok (zdieľané `pw/userdata` + `out/` → poškodenie indexu).
5. **Needituj `run.sh` počas behu** (bash re-readne posunutý offset → spustí nesprávny kód).

---

## Štruktúra

| Cesta | Popis |
|---|---|
| `setup.sh` | bootstrap (upstream + Playwright + stav) |
| `run.sh` | odolný supervisor (tmux) |
| `restart.sh` | čistý reštart na zadané tempo (jediná cesta ako meniť throttle) |
| `stepdown-controller.sh` | adaptívne rozhodnutie o tempe |
| `status.sh` / `verify.sh` | počty / obsahová validácia |
| `wait-and-start.sh` | čakanie na token + štart |
| `pw/browser-export.js` | Cloudflare-bypass fetch proxy + spustenie upstreamu |
| `pw/lockout-test.js` | jednorazový test, či rate-limit lockout ustúpil |
| `viewer/` | lokálny webový prehliadač (port cez `VIEWER_PORT`) |
| `docs/` | architektúra, rate-limity, monitoring, reprodukcia |
| `prompts/` | šablóny loop promptov (monitoring, čakanie na token) |
| `AGENTS.md` | operačný ťahák pre AI agentov (anglicky) |

## Kredit a licencia
Jadro exportu: [`brianjlacy/export-chatgpt`](https://github.com/brianjlacy/export-chatgpt) (MIT).
Nie je vendorovaný — `setup.sh` ho klonuje na pinnutý commit `4cfc3f2` do `tool/` a ostáva
pod vlastnou licenciou. Tento toolkit pridáva Cloudflare bypass, adaptívne tempo, monitoring
loop, validáciu a prehliadač; licencia [MIT](LICENSE).
