# Architektúra

## Problém
ChatGPT `backend-api` je za Cloudflare **„managed challenge"** (`cf-mitigated: challenge`).
Obyčajný `fetch`/`curl` (aj s platným tokenom) dostane **403** s HTML challenge stránkou.
Upstream nástroj to mylne hlási ako „expired token", hoci token je v poriadku.

## Riešenie: prehliadačom routovaný fetch
`pw/browser-export.js` spustí **reálny Chromium** (Playwright) pod `xvfb` (headful), ktorý
Cloudflare challenge prejde automaticky a získa `cf_clearance` cookie. Potom **prepíše
`globalThis.fetch`**:

- **host `chatgpt.com`** → fetch sa vykoná **vnútri stránky** (`page.evaluate(fetch …)`),
  teda same-origin s `cf_clearance` + pravým Chrome TLS fingerprintom. Telo sa prenáša
  ako base64 (funguje pre text aj binárku) a zabalí do `Response`-like objektu.
- **iný host** (podpísané CDN download URL pre prílohy) → **natívny** `fetch` (bez challenge).

Následne `require(tool/lib/cli.js).main()` rozbehne **nezmenený** upstream export — celá
jeho logika (stránkovanie, projekty, markdown, súbory, resume) funguje, mení sa len
transportná vrstva.

Pri pretrvávajúcej challenge sa stránka reloadne (až 5×); ak ani tak neprejde, vráti sa
`503` (prechodná chyba → retry), **nie** auth-fail (aby zbytočne nepýtal nový token).

## Komponenty

```
run.sh  (tmux "cgpt", nekonečná slučka)
  │  čítaj token.txt -> CHATGPT_BEARER_TOKEN (env), account-id z JWT
  └─ xvfb-run -a node pw/browser-export.js
        │  launchPersistentContext(pw/userdata)  -> goto chatgpt.com (prejde CF)
        │  overenie /backend-api/me  -> log "prihlásený ako <email>"
        │  globalThis.fetch = browserFetch
        └─ main() z tool/lib/cli.js  (argv: --non-interactive --include-archived
                                       --throttle <.throttle> --output out/ --account-id <jwt>)
  exit 0 -> "HOTOVO"; 429 -> wait 5m; auth-fail -> čakaj na nový token; iné -> wait 5m
```

- **`browser-export.js`** číta `EXPORT_DIR` z `path.resolve(__dirname, '..')` → priečinok je
  prenositeľný (funguje pre ľubovoľný názov priečinka / viac účtov).
- **Throttle** sa NEčíta z kódu, ale zo súboru `.throttle` (+`.min-throttle`) → tempo sa dá
  meniť medzi reštartmi bez editovania JS.
- **Account-id** sa ťahá z JWT (`chatgpt_account_id`) → funguje aj pre Business/Team.
  Pozn.: v Team workspace je account-id zdieľaný; **Bearer token (user `sub`)** určuje, čie
  konverzácie sa stiahnu, a výstup ide do `out/<user-id>/` (per-používateľ izolované).

## Výstup
```
out/<user-id>/
  json/        *.json   (surové konverzácie)
  *.md /markdown/        (čitateľný markdown)
  files/                 (prílohy/assety bežných konverzácií)
  projects/<projekt>/json|files/   (projektové konverzácie a ich prílohy)
  conversation-index.json, projects/project-index.json
  .export-progress.json  (resume stav)
```

## Stavové súbory (v koreni priečinka)
| Súbor | Význam |
|---|---|
| `.throttle` / `.min-throttle` | aktuálne tempo (s/dopyt), číta `browser-export.js` |
| `.cooldown-until` | epoch, dokedy NEspúšťať (po lockoute) |
| `.stable-count` / `.last-count` | controller: koľko čistých kontrol / posledný počet |
| `.last-probe` | epoch posledného 15 s probe |
| `.wait-count` | počítadlo pokusov čakania na token |
| `.runner-state` | posledné nastavené tempo |
