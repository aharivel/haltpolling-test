#!/usr/bin/env bash
# measure.sh <label> <hp_ns> <duration_s>
set -euo pipefail
LABEL=$1; HPNS=$2; DUR=${3:-300}
KVMD=/sys/kernel/debug/kvm; OUT=runs/$LABEL; mkdir -p "$OUT"

echo "[measure] label=$LABEL hp_ns=$HPNS dur=${DUR}s out=$OUT"

echo "$HPNS" > /sys/module/kvm/parameters/halt_poll_ns
echo "halt_poll_ns=$(cat /sys/module/kvm/parameters/halt_poll_ns)" > "$OUT/arm"
echo "[measure] halt_poll_ns set to $HPNS"

read_halt(){ for f in halt_exits halt_attempted_poll halt_successful_poll halt_poll_invalid \
  halt_poll_success_ns halt_poll_fail_ns halt_wait_ns; do
  printf '%s %s\n' "$f" "$(cat "$KVMD/$f")"; done; }

read_halt > "$OUT/halt.t0"
echo "[measure] halt counters t0 captured"

python /root/power-measurement-toolkit/power_monitor.py > "$OUT/power.csv" 2>&1 & PM=$!
echo "[measure] power_monitor started (PID $PM)"

turbostat --interval 5 --quiet --Summary \
  --show PkgWatt,RAMWatt,Busy%,Bzy_MHz,CPU%c1,CPU%c6,Pkg%pc2,Pkg%pc6,CoreTmp \
  --out "$OUT/turbostat.txt" & TS=$!
echo "[measure] turbostat started (PID $TS)"

echo "[measure] sleeping ${DUR}s..."
sleep "$DUR"
echo "[measure] sleep done, stopping collectors"

kill -INT "$PM" 2>/dev/null || true
kill "$TS" 2>/dev/null || true
wait 2>/dev/null || true

read_halt > "$OUT/halt.t1"
join "$OUT/halt.t0" "$OUT/halt.t1" | awk '{printf "%-26s %d\n",$1,$3-$2}' > "$OUT/halt.delta"
echo "[measure] done -> $OUT  (window=${DUR}s, halt_poll_ns=$HPNS)"
