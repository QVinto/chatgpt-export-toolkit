#!/usr/bin/env bash
# status.sh — rýchly prehľad stavu exportu (počty súborov v ~/chatgpt-export/out)
set -uo pipefail
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/out"

if [ ! -d "$OUT_DIR" ]; then
  echo "out/ ešte neexistuje"
  exit 0
fi

# Bežné konverzácie = JSON súbory v <uid>/json/
reg_json=$(find "$OUT_DIR" -type f -path '*/json/*.json' ! -path '*/projects/*' 2>/dev/null | wc -l)
# Projektové konverzácie = JSON súbory v <uid>/projects/<proj>/json/
proj_json=$(find "$OUT_DIR" -type f -path '*/projects/*/json/*.json' 2>/dev/null | wc -l)
conv_total=$((reg_json + proj_json))

# Markdown konverzácie (kontrolný počet)
md_total=$(find "$OUT_DIR" -type f -name '*.md' 2>/dev/null | wc -l)

# Počet projektov = priečinky v projects/ (okrem project-index.json)
proj_count=0
proj_dir=$(find "$OUT_DIR" -type d -name projects 2>/dev/null | head -n1)
if [ -n "${proj_dir:-}" ] && [ -d "$proj_dir" ]; then
  proj_count=$(find "$proj_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
fi
# Alebo presnejšie z project-index.json, ak existuje
pidx=$(find "$OUT_DIR" -type f -name 'project-index.json' 2>/dev/null | head -n1)
proj_idx_count="(n/a)"
if [ -n "${pidx:-}" ] && [ -f "$pidx" ]; then
  proj_idx_count=$(grep -c '"id"' "$pidx" 2>/dev/null || echo "?")
fi

# Stiahnuté súbory/assety
asset_count=$(find "$OUT_DIR" -type f -path '*/files/*' 2>/dev/null | wc -l)

# Veľkosť
size=$(du -sh "$OUT_DIR" 2>/dev/null | cut -f1)

# Index a progres
idx_file=$(find "$OUT_DIR" -type f -name 'conversation-index.json' ! -path '*/projects/*' 2>/dev/null | head -n1)
idx_count="(n/a)"
if [ -n "${idx_file:-}" ] && [ -f "$idx_file" ]; then
  idx_count=$(grep -c '"id"' "$idx_file" 2>/dev/null || echo "?")
fi

echo "=== STAV EXPORTU ($(date '+%Y-%m-%d %H:%M:%S')) ==="
echo "Konverzácie stiahnuté (JSON):  $conv_total   (bežné: $reg_json | projektové: $proj_json)"
echo "Markdown súbory:               $md_total"
echo "Projekty (priečinky):          $proj_count   | v project-index.json: $proj_idx_count"
echo "Konverzácie v hlavnom indexe:  $idx_count"
echo "Stiahnuté súbory/assety:       $asset_count"
echo "Veľkosť out/:                  ${size:-?}"
