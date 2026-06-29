#!/usr/bin/env bash
# run_h2_latency.sh — targeted H2 test: tail latency per arm
# Runs sockperf per-arm (not across arms) to get clean latency distributions.
# 2 vCPUs, 3 reps × 2 arms × 60s, at 5000 and 10000 mps (where savings exist).
# Usage: ./run_h2_latency.sh [guest_ip]
set -euo pipefail

GUEST_IP=${1:-192.168.122.244}
SSHCMD="ssh -o StrictHostKeyChecking=no root@$GUEST_IP"
LOG=runs/h2_latency_$(date +%Y%m%d_%H%M%S).log

exec > >(tee -a "$LOG") 2>&1
echo "=== H2 LATENCY TEST started at $(date) ==="

# ---------- Offline guest vCPUs 2-7 ----------
echo "Offlining guest vCPUs 2-7..."
$SSHCMD 'for c in 2 3 4 5 6 7; do echo 0 > /sys/devices/system/cpu/cpu${c}/online 2>/dev/null; done'
$SSHCMD 'cat /sys/devices/system/cpu/online'

for mps in 5000 10000; do
  echo ""
  echo "===== H2 @ ${mps} mps ====="

  for rep in 1 2 3; do
    for hp in $(shuf -e 0 200000); do
      TAG="h2_${mps}_hp${hp}_r${rep}"
      echo "[h2] $TAG — setting hp=$hp"
      echo "$hp" > /sys/module/kvm/parameters/halt_poll_ns
      echo "[h2] readback: $(cat /sys/module/kvm/parameters/halt_poll_ns)"

      # Restart sockperf server
      $SSHCMD 'pkill sockperf 2>/dev/null; sleep 1; nohup sockperf server --tcp -i 0.0.0.0 -p 11111 </dev/null >/dev/null 2>&1 &'
      sleep 2

      echo "[h2] $TAG — warmup 15s..."
      # Start generator and let it warm up
      taskset -c 9,11 sockperf under-load --tcp -i $GUEST_IP -p 11111 \
        -t 90 --mps=$mps --full-rtt > "runs/${TAG}_latency.txt" 2>&1 &
      GEN=$!

      sleep 15  # warmup (first 15s of the 90s run)
      # The remaining 75s is the measurement window
      # (sockperf captures full run stats including warmup, but warmup is short)

      echo "[h2] $TAG — measuring ~75s..."
      wait $GEN 2>/dev/null || true

      echo "[h2] $TAG — latency results:"
      grep -E '(avg-latency|percentile 99\.|percentile 50\.|percentile 75\.|percentile 90\.|MAX|MIN|dropped)' \
        "runs/${TAG}_latency.txt" 2>/dev/null || echo "  (no results)"

      echo "[h2] $TAG — settle 30s..."
      sleep 30
    done
  done
done

# Re-online vCPUs
$SSHCMD 'for c in 2 3 4 5 6 7; do echo 1 > /sys/devices/system/cpu/cpu${c}/online 2>/dev/null; done'
$SSHCMD 'pkill sockperf' 2>/dev/null || true

echo ""
echo "=== H2 LATENCY TEST finished at $(date) ==="
echo ""
echo "Summary:"
echo "--- hp=0 ---"
for f in runs/h2_*_hp0_*_latency.txt; do
  echo "$(basename $f):"
  grep -E '(avg-latency|percentile 99\.9|MAX)' "$f" 2>/dev/null | sed 's/^/  /'
done
echo ""
echo "--- hp=200000 ---"
for f in runs/h2_*_hp200000_*_latency.txt; do
  echo "$(basename $f):"
  grep -E '(avg-latency|percentile 99\.9|MAX)' "$f" 2>/dev/null | sed 's/^/  /'
done
