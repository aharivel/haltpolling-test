#!/usr/bin/env bash
# run_verify.sh — paranoid verification run: fewer reps, shorter, extra logging
# Proves the IV is actually toggling and measurements respond.
# Run as root from repo dir.
set -euo pipefail

GUEST_IP=${1:-192.168.122.244}
SSHCMD="ssh -o StrictHostKeyChecking=no root@$GUEST_IP"
LOG=runs/verify_$(date +%Y%m%d_%H%M%S).log
KVMD=/sys/kernel/debug/kvm

exec > >(tee -a "$LOG") 2>&1
echo "=== VERIFICATION RUN started at $(date) ==="

# ---------- Pre-flight checks ----------
echo ""
echo "===== PRE-FLIGHT CHECKS ====="
echo "[check] halt_poll_ns BEFORE: $(cat /sys/module/kvm/parameters/halt_poll_ns)"
echo "[check] cpuidle driver: $(cat /sys/devices/system/cpu/cpuidle/current_driver)"
echo "[check] intel_pstate no_turbo: $(cat /sys/devices/system/cpu/intel_pstate/no_turbo)"
echo "[check] isolated CPUs: $(cat /sys/devices/system/cpu/isolated)"
echo "[check] irqbalance: $(systemctl is-active irqbalance 2>/dev/null || echo 'not running')"
echo "[check] VMs running:"
virsh list
echo "[check] VM vcpupin:"
virsh vcpupin halt-test
echo "[check] VM emulatorpin:"
virsh emulatorpin halt-test
echo "[check] Guest cpuidle: $($SSHCMD 'cat /sys/devices/system/cpu/cpuidle/current_driver' 2>/dev/null || echo 'SSH failed')"
echo ""

# ---------- V1: Toggle test (no workload) — prove IV moves counters ----------
echo "===== V1: IV TOGGLE TEST (20s each, no workload, idle VM) ====="

for hp in 0 200000 0 200000; do
  echo "$hp" > /sys/module/kvm/parameters/halt_poll_ns
  actual=$(cat /sys/module/kvm/parameters/halt_poll_ns)
  echo "[V1] SET halt_poll_ns=$hp → READBACK=$actual"
  if [[ "$actual" != "$hp" ]]; then
    echo "[V1] *** MISMATCH! Wrote $hp, read $actual ***"
    exit 1
  fi

  # Snapshot halt counters
  t0_exits=$(cat $KVMD/halt_exits)
  t0_attempted=$(cat $KVMD/halt_attempted_poll)
  t0_success=$(cat $KVMD/halt_successful_poll)
  t0_success_ns=$(cat $KVMD/halt_poll_success_ns)
  t0_fail_ns=$(cat $KVMD/halt_poll_fail_ns)
  t0_wait_ns=$(cat $KVMD/halt_wait_ns)

  sleep 20

  t1_exits=$(cat $KVMD/halt_exits)
  t1_attempted=$(cat $KVMD/halt_attempted_poll)
  t1_success=$(cat $KVMD/halt_successful_poll)
  t1_success_ns=$(cat $KVMD/halt_poll_success_ns)
  t1_fail_ns=$(cat $KVMD/halt_poll_fail_ns)
  t1_wait_ns=$(cat $KVMD/halt_wait_ns)

  d_exits=$((t1_exits - t0_exits))
  d_attempted=$((t1_attempted - t0_attempted))
  d_success=$((t1_success - t0_success))
  d_success_ns=$((t1_success_ns - t0_success_ns))
  d_fail_ns=$((t1_fail_ns - t0_fail_ns))
  d_wait_ns=$((t1_wait_ns - t0_wait_ns))

  echo "[V1]   hp=$hp: exits=$d_exits attempted=$d_attempted success=$d_success"
  echo "[V1]   success_ns=$d_success_ns fail_ns=$d_fail_ns wait_ns=$d_wait_ns"

  if [[ "$hp" == "0" ]]; then
    if [[ "$d_attempted" -ne 0 ]]; then
      echo "[V1]   *** BUG: hp=0 but attempted_poll=$d_attempted (should be 0) ***"
    else
      echo "[V1]   OK: hp=0 → no polling attempted"
    fi
  else
    if [[ "$d_attempted" -eq 0 && "$d_exits" -gt 0 ]]; then
      echo "[V1]   *** WARNING: hp=200000 but no polls attempted despite $d_exits exits ***"
    else
      echo "[V1]   OK: hp=200000 → $d_attempted polls attempted"
    fi
  fi
  echo ""
done

# ---------- V2: Quick power comparison (60s each arm, 3 reps) ----------
echo "===== V2: QUICK POWER TEST (3 reps × 2 arms × 60s) ====="
echo "[V2] Using idle VM — should show max HP effect if any"
echo ""

for rep in 1 2 3; do
  for hp in $(shuf -e 0 200000); do
    echo "$hp" > /sys/module/kvm/parameters/halt_poll_ns
    actual=$(cat /sys/module/kvm/parameters/halt_poll_ns)
    echo "[V2] rep=$rep hp=$hp (readback=$actual) — warmup 30s..."
    sleep 30

    echo "[V2] rep=$rep hp=$hp — measuring 60s..."
    ./measure.sh "verify_hp${hp}_r${rep}" "$hp" 60
  done
done

echo ""
echo "===== V2 RESULTS ====="
echo ""
echo "--- hp=0 runs ---"
for d in runs/verify_hp0_r*/; do
  label=$(basename $d)
  arm=$(cat $d/arm)
  echo -n "[V2] $label ($arm): "
  # Inline turbostat summary
  if [[ -f "$d/turbostat.txt" ]]; then
    head -1 "$d/turbostat.txt"
    tail -1 "$d/turbostat.txt" | head -1
  fi
  # Power
  if [[ -f "$d/power.csv" ]]; then
    echo -n "  IPMI/RAPL last line: "
    grep "RAPL" "$d/power.csv" | tail -1
  fi
  # Halt delta
  if [[ -f "$d/halt.delta" ]]; then
    echo "  halt.delta:"
    cat "$d/halt.delta" | sed 's/^/    /'
  fi
  echo ""
done

echo "--- hp=200000 runs ---"
for d in runs/verify_hp200000_r*/; do
  label=$(basename $d)
  arm=$(cat $d/arm)
  echo -n "[V2] $label ($arm): "
  if [[ -f "$d/turbostat.txt" ]]; then
    head -1 "$d/turbostat.txt"
    tail -1 "$d/turbostat.txt" | head -1
  fi
  if [[ -f "$d/power.csv" ]]; then
    echo -n "  IPMI/RAPL last line: "
    grep "RAPL" "$d/power.csv" | tail -1
  fi
  if [[ -f "$d/halt.delta" ]]; then
    echo "  halt.delta:"
    cat "$d/halt.delta" | sed 's/^/    /'
  fi
  echo ""
done

echo ""
echo "=== VERIFICATION RUN finished at $(date) ==="
echo "Quick parse:"
python3 parse_runs.py runs | head -1
python3 parse_runs.py runs | grep verify
