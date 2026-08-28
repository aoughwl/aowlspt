#!/usr/bin/env bash
# Batch extract+verify every remaining EFT map into the shared tt pool.
# Runs under the Store Python (fact #163). One line per map to the progress log.
set -u
WT="C:/Users/savant/AppData/Local/Temp/wt-mapall"
PY="$LOCALAPPDATA/Microsoft/WindowsApps/python.exe"
OUT="D:/MapExtract/tt"
LOG="$OUT/_extract_all_progress.log"
cd "$WT"

# smallest first so partial progress shows quickly; done maps excluded
MAPS="arena_preset develop_preset labyrinth_preset sandbox_start_preset laboratory_dark_preset laboratory_preset factory_night_preset sandbox_preset sandbox_high_preset icebreaker rezerv_base_preset customs_preset shopping_mall lighthouse_preset shoreline_preset terminal_preset city_preset"

echo "=== batch start $(date -u +%FT%TZ) ===" >> "$LOG"
for M in $MAPS; do
  echo "--- $M extract start $(date -u +%FT%TZ) ---" >> "$LOG"
  "$PY" tools/mapextract.py --out "$OUT" extract "$M" > "$OUT/${M}.extract.log" 2>&1
  ERC=$?
  VOUT=$("$PY" tools/mapextract.py --out "$OUT" verify "$M" 2>&1)
  VRC=$?
  echo "$VOUT" > "$OUT/${M}.verify.log"
  SUM=$(echo "$VOUT" | tail -1)
  SZ=$(du -sh "$OUT/$M" 2>/dev/null | cut -f1)
  echo "$M  extractRC=$ERC verifyRC=$VRC size=$SZ  $SUM" >> "$LOG"
done
POOL=$(du -sh "$OUT/_textures" 2>/dev/null | cut -f1)
TOT=$(du -sh "$OUT" 2>/dev/null | cut -f1)
echo "=== batch done $(date -u +%FT%TZ) pool=$POOL total=$TOT ===" >> "$LOG"
