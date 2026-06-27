#!/usr/bin/env bash
# verify.sh — REÁLNA obsahová validácia stiahnutých dát (nie len počet súborov).
# Kontroluje: platnosť JSON konverzácií + prítomnosť správ, prázdne/poškodené
# súbory, a či assety nie sú HTML/Cloudflare stránky uložené ako súbor.
set -uo pipefail
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/out"
UDIR="$(find "$OUT_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n1)"
[ -z "$UDIR" ] && { echo "out/ ešte nemá user priečinok"; exit 0; }

echo "=== OBSAHOVÁ VALIDÁCIA ($(date '+%H:%M:%S')) ==="
node -e '
const fs=require("fs"), path=require("path");
const root=process.argv[1];
let dirs=[];
const jdir=path.join(root,"json"); if(fs.existsSync(jdir)) dirs.push(jdir);
const pdir=path.join(root,"projects");
if(fs.existsSync(pdir)) for(const p of fs.readdirSync(pdir)){const jd=path.join(pdir,p,"json"); if(fs.existsSync(jd)) dirs.push(jd);}
let total=0, okMsg=0, noMsg=0, bad=[], empty=[];
for(const d of dirs) for(const f of fs.readdirSync(d)){
  if(!f.endsWith(".json")) continue; total++;
  const fp=path.join(d,f); const sz=fs.statSync(fp).size;
  if(sz===0){empty.push(f);continue;}
  let data; try{data=JSON.parse(fs.readFileSync(fp,"utf8"));}catch(e){bad.push(f);continue;}
  const nodes=Object.values(data.mapping||{});
  if(nodes.length===0){bad.push(f+"(no-mapping)");continue;}
  const msgs=nodes.filter(n=>n&&n.message&&n.message.content).length;
  if(msgs>0) okMsg++; else noMsg++;
}
console.log("  JSON konverzácie:   "+total+"  | s správami: "+okMsg+" | bez správ: "+noMsg);
console.log("  prázdne (0B): "+empty.length+(empty.length?(" -> "+empty.slice(0,5).join(", ")):""));
console.log("  POŠKODENÉ:    "+bad.length+(bad.length?(" -> "+bad.slice(0,5).join(", ")):""));
process.exitCode = (bad.length||empty.length)?1:0;
' "$UDIR"
rc=$?

# Assety: 0B + HTML/Cloudflare
ztotal=$(find "$UDIR" -path '*/files/*' -type f 2>/dev/null | wc -l)
zzero=$(find "$UDIR" -path '*/files/*' -type f -size 0 2>/dev/null | wc -l)
zhtml=0
while IFS= read -r f; do
  head -c 200 "$f" 2>/dev/null | grep -qiE '<html|cloudflare|just a moment|<!doctype' && { echo "  PODOZRIVÝ ASSET: $f"; zhtml=$((zhtml+1)); }
done < <(find "$UDIR" -path '*/files/*' -type f 2>/dev/null)
echo "  Assety: $ztotal  | 0B: $zzero | HTML/CF podozrivé: $zhtml"

[ "$rc" = 0 ] && [ "$zzero" = 0 ] && [ "$zhtml" = 0 ] && echo "  VÝSLEDOK: ✅ OK" || echo "  VÝSLEDOK: ⚠️ pozri vyššie"
