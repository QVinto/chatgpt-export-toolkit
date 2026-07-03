#!/usr/bin/env bash
# status.sh — quick overview of the export state (file counts in <folder>/out)
set -uo pipefail
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/out"

if [ ! -d "$OUT_DIR" ]; then
  echo "out/ does not exist yet"
  exit 0
fi

# Regular conversations = JSON files in <uid>/json/
reg_json=$(find "$OUT_DIR" -type f -path '*/json/*.json' ! -path '*/projects/*' 2>/dev/null | wc -l)
# Project conversations = JSON files in <uid>/projects/<proj>/json/
proj_json=$(find "$OUT_DIR" -type f -path '*/projects/*/json/*.json' 2>/dev/null | wc -l)
conv_total=$((reg_json + proj_json))

# Markdown conversations (cross-check count)
md_total=$(find "$OUT_DIR" -type f -name '*.md' 2>/dev/null | wc -l)

# Project count = folders in projects/ (excluding project-index.json)
proj_count=0
proj_dir=$(find "$OUT_DIR" -type d -name projects 2>/dev/null | head -n1)
if [ -n "${proj_dir:-}" ] && [ -d "$proj_dir" ]; then
  proj_count=$(find "$proj_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
fi
# Or, more precisely, from project-index.json if it exists
pidx=$(find "$OUT_DIR" -type f -name 'project-index.json' 2>/dev/null | head -n1)
proj_idx_count="(n/a)"
if [ -n "${pidx:-}" ] && [ -f "$pidx" ]; then
  proj_idx_count=$(grep -c '"id"' "$pidx" 2>/dev/null || echo "?")
fi

# Downloaded files/assets
asset_count=$(find "$OUT_DIR" -type f -path '*/files/*' 2>/dev/null | wc -l)

# Size
size=$(du -sh "$OUT_DIR" 2>/dev/null | cut -f1)

# Index and progress
idx_file=$(find "$OUT_DIR" -type f -name 'conversation-index.json' ! -path '*/projects/*' 2>/dev/null | head -n1)
idx_count="(n/a)"
if [ -n "${idx_file:-}" ] && [ -f "$idx_file" ]; then
  idx_count=$(grep -c '"id"' "$idx_file" 2>/dev/null || echo "?")
fi

echo "=== EXPORT STATUS ($(date '+%Y-%m-%d %H:%M:%S')) ==="
echo "Conversations downloaded (JSON):  $conv_total   (regular: $reg_json | project: $proj_json)"
echo "Markdown files:                   $md_total"
echo "Projects (folders):               $proj_count   | in project-index.json: $proj_idx_count"
echo "Conversations in main index:      $idx_count"
echo "Downloaded files/assets:          $asset_count"
echo "Size of out/:                     ${size:-?}"
