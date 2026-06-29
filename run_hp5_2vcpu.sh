#!/usr/bin/env bash
# run_hp5_2vcpu.sh — HP-5 load sweep with 2 active vCPUs (idle gaps hit poll window)
# Run as root from repo dir. VM must be running.
# Usage: ./run_hp5_2vcpu.sh [guest_ip]
set -euo pipefail

GUEST_IP=${1:-192.168.122.244}
SSHCMD="ssh -o StrictHostKeyChecking=no root@$GUEST_IP"
LOG=runs/hp5_2vcpu_$(date +%Y%m%d_%H%M%S).log

exec > >(tee -a "$LOG") 2>&1
echo "=== HP-5 (2 vCPU) run started at $(date) ==="

# ---------- Pre-flight ----------
echo ""
echo "===== PRE-FLIGHT ====="
echo "[check] halt_poll_ns: $(cat /sys/module/kvm/parameters/halt_poll_ns)"
echo "[check] no_turbo: $(cat /sys/devices/system/cpu/intel_pstate/no_turbo)"
virsh list
virsh vcpupin halt-test

# ---------- Offline 6 of 8 guest vCPUs ----------
echo ""
echo "===== OFFLINING GUEST vCPUs 2-7 ====="
$SSHCMD 'for c in 2 3 4 5 6 7; do
  echo 0 > /sys/devices/system/cpu/cpu${c}/online
  echo "cpu$c: $(cat /sys/devices/system/cpu/cpu${c}/online)"
done'
echo "[check] Guest online CPUs:"
$SSHCMD 'cat /sys/devices/system/cpu/online'
echo ""

# ---------- Start sockperf server ----------
$SSHCMD 'pkill sockperf || true; sleep 1; nohup sockperf server --tcp -i 0.0.0.0 -p 11111 </dev/null >/dev/null 2>&1 &'
sleep 3
echo "sockperf server started (2 vCPUs active)"

# ---------- Quick sanity: ping-pong ----------
echo ""
echo "===== SANITY: sockperf ping-pong 5s ====="
taskset -c 9 sockperf ping-pong --tcp -i $GUEST_IP -p 11111 -t 5 2>&1 | tail -5
echo ""

# ---------- HP-5 sweep: 1000, 2000, 5000, 10000, 20000 mps ----------
echo "===== HP-5 LOAD SWEEP (2 vCPU, 3 reps × 2 arms × 120s) ====="
for mps in 1000 2000 5000 10000 20000; do
  echo ""
  echo "--- HP-5 @ ${mps} mps (${mps}/2 = $((mps/2)) per vCPU) ---"

  # Restart sockperf server (clean state)
  $SSHCMD 'pkill sockperf || true; sleep 1; nohup sockperf server --tcp -i 0.0.0.0 -p 11111 </dev/null >/dev/null 2>&1 &'
  sleep 3

  taskset -c 9,11 sockperf under-load --tcp -i $GUEST_IP -p 11111 \
    -t 99999 --mps=$mps --full-rtt > "runs/hp5_2v_txn${mps}_sockperf.txt" 2>&1 &
  GEN=$!
  sleep 10

  # 3 reps, 120s each, 30s warmup, 60s settle
  TAG="hp5_2v_txn${mps}"
  echo "[run] Starting $TAG at $(date)"
  for rep in 1 2 3; do
    for hp in $(shuf -e 0 200000); do
      echo "[run] rep=$rep hp=$hp — warmup 30s..."
      sleep 30
      echo "[run] rep=$rep hp=$hp — measuring 120s..."
      ./measure.sh "${TAG}_hp${hp}_r${rep}" "$hp" 120
      echo "[run] rep=$rep hp=$hp — settle 45s..."
      sleep 45
    done
  done

  kill $GEN 2>/dev/null || true; wait $GEN 2>/dev/null || true
  echo "[run] $TAG done at $(date)"
done

# ---------- Re-online vCPUs ----------
echo ""
echo "===== RE-ONLINING GUEST vCPUs ====="
$SSHCMD 'for c in 2 3 4 5 6 7; do echo 1 > /sys/devices/system/cpu/cpu${c}/online; done'
$SSHCMD 'cat /sys/devices/system/cpu/online'

# ---------- Cleanup ----------
$SSHCMD 'pkill sockperf' 2>/dev/null || true

echo ""
echo "=== HP-5 (2 vCPU) run finished at $(date) ==="
echo ""
echo "Quick results:"
python3 parse_runs.py runs | head -1
python3 parse_runs.py runs | grep hp5_2v
