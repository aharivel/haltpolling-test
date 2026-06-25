#!/usr/bin/env bash
# measure.sh <label> <hp_ns> <duration_s>
set -euo pipefail
LABEL=$1; HPNS=$2; DUR=${3:-300}
KVMD=/sys/kernel/debug/kvm; OUT=runs/$LABEL; mkdir -p "$OUT"

echo "$HPNS" > /sys/module/kvm/parameters/halt_poll_ns
echo "halt_poll_ns=$(cat /sys/module/kvm/parameters/halt_poll_ns)" > "$OUT/arm"

read_halt(){ for f in halt_exits halt_attempted_poll halt_successful_poll halt_poll_invalid \
  halt_poll_success_ns halt_poll_fail_ns halt_wait_ns; do
  printf '%s %s\n' "$f" "$(cat "$KVMD/$f")"; done; }

read_halt > "$OUT/halt.t0"
python power_monitor.py > "$OUT/power.csv" 2>&1 & PM=$!
# --Summary => one system-summary row per interval (easy to parse):
turbostat --interval 5 --quiet --Summary \
  --show PkgWatt,RAMWatt,Busy%,Bzy_MHz,CPU%c1,CPU%c6,Pkg%pc2,Pkg%pc6,CoreTmp \
  --out "$OUT/turbostat.txt" & TS=$!

sleep "$DUR"
kill -INT "$PM" 2>/dev/null || true
kill "$TS" 2>/dev/null || true
wait 2>/dev/null || true

read_halt > "$OUT/halt.t1"
join "$OUT/halt.t0" "$OUT/halt.t1" | awk '{printf "%-26s %d\n",$1,$3-$2}' > "$OUT/halt.delta"
echo "done -> $OUT  (window=${DUR}s, halt_poll_ns=$HPNS)"
