#!/bin/bash
# A save-state chain on its own, read back after a load and again after a save
# (src/sim/chains). Today the Arcade Card's: bash tools/chain-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
B=build/chain-test
rm -rf "$B"; mkdir -p "$B"
verilator --binary -Wno-fatal -Wno-lint -Wno-style -Wno-PROCASSWIRE --timing -Mdir "$B" --top-module arcade_tb \
  src/sim/chains/arcade_tb.sv src/fpga/core/rtl/arcade.sv > "$B/verilator.log" 2>&1 \
  || { grep -E '%Error' "$B/verilator.log" | head; exit 1; }
"$B/Varcade_tb" | tee "$B/out.txt"
grep -q ": ok" "$B/out.txt"
