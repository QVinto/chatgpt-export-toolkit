#!/usr/bin/env bash
# verify.sh — REAL content validation of the downloaded data (not just a file count).
# Checks: valid JSON conversations + presence of messages, empty/corrupted
# files, and whether assets are HTML/Cloudflare pages saved as a file.
set -uo pipefail
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/out"
UDIR="$(find "$OUT_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n1)"
[ -z "$UDIR" ] && { echo "out/ has no user folder yet"; exit 0; }

echo "=== CONTENT VALIDATION ($(date '+%H:%M:%S')) ==="
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
console.log("  JSON conversations: "+total+"  | with messages: "+okMsg+" | without messages: "+noMsg);
console.log("  empty (0B): "+empty.length+(empty.length?(" -> "+empty.slice(0,5).join(", ")):""));
console.log("  CORRUPTED:  "+bad.length+(bad.length?(" -> "+bad.slice(0,5).join(", ")):""));
process.exitCode = (bad.length||empty.length)?1:0;
' "$UDIR"
rc=$?

# Assets: 0B + HTML/Cloudflare
ztotal=$(find "$UDIR" -path '*/files/*' -type f 2>/dev/null | wc -l)
zzero=$(find "$UDIR" -path '*/files/*' -type f -size 0 2>/dev/null | wc -l)
zhtml=0
while IFS= read -r f; do
  head -c 200 "$f" 2>/dev/null | grep -qiE '<html|cloudflare|just a moment|<!doctype' && { echo "  SUSPICIOUS ASSET: $f"; zhtml=$((zhtml+1)); }
done < <(find "$UDIR" -path '*/files/*' -type f 2>/dev/null)
echo "  Assets: $ztotal  | 0B: $zzero | HTML/CF suspicious: $zhtml"

[ "$rc" = 0 ] && [ "$zzero" = 0 ] && [ "$zhtml" = 0 ] && echo "  RESULT: ✅ OK" || echo "  RESULT: ⚠️ see above"
