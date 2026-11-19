#!/bin/sh
# PC Engine CD for Analogue Pocket: the bridge's watchdog on the target commands, in Verilator.
#
#   tools/bridge-test.sh
#
# core_bridge_cmd.v asks a command to the Pocket again when it is left in the mailbox or
# never finished, as after a game chosen in Core Settings reloads the bitstream. A stand-in
# Pocket (src/sim/bridge/watchdog_tb.sv) answers every command, leaves slot 100's name in the
# mailbox, takes it up and never finishes it, or never answers Ready to Run. Each run must get
# the name and then a read done: green when all four do. A minute or so.

set -eu
cd "$(dirname "$0")/.."
out=build/sim/bridge
rm -rf "$out"
mkdir -p "$out"
fail=0
for mode in 0 1 2 3; do
  verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -DSIM_PORT -GMODE=$mode \
    --top-module tb -Mdir "$out/obj$mode" src/sim/bridge/watchdog_tb.sv \
    src/fpga/MPU/core_bridge_cmd.v src/fpga/apf/common.v > "$out/build$mode.log" 2>&1
  "$out/obj$mode/Vtb" > "$out/run$mode.log" 2>&1 || true
  echo "== mode $mode ($((mode + 1)) of 4)"
  grep -E "PASS|FAIL" "$out/run$mode.log" || true
  [ "$(grep -c PASS "$out/run$mode.log")" = 2 ] || fail=1
done
rm -rf "$out"
if [ $fail = 0 ]; then printf '\033[32mbridge watchdog: all good\033[0m\n'; else printf '\033[31mbridge watchdog: FAILED\033[0m\n'; exit 1; fi
