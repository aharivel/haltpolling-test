#!/usr/bin/env bash
# run_hp4-6.sh — run HP-4 (single txn), HP-5 (load sweep), HP-6 (bursty vs steady)
# Run as root from repo dir. sockperf must be installed on guest + host.
# Usage: ./run_hp4-6.sh [guest_ip]
set -euo pipefail

GUEST_IP=${1:-192.168.122.244}
LOG=runs/hp4-6_$(date +%Y%m%d_%H%M%S).log
SSHCMD="ssh -o StrictHostKeyChecking=no root@$GUEST_IP"

exec > >(tee -a "$LOG") 2>&1
echo "=== HP-4/5/6 run started at $(date) ==="

# Ensure sockperf server running in guest
$SSHCMD 'pkill sockperf || true; sleep 1; nohup sockperf server --tcp -i 0.0.0.0 -p 11111 </dev/null >/dev/null 2>&1 &'
sleep 3
echo "sockperf server started in guest"

# ---------- HP-4: single-point transactional load (2000 mps) ----------
echo ""
echo "===== HP-4: transactional load @ 2000 mps ====="
# Generator on node1 isolated cores (off measured socket)
taskset -c 9,11 sockperf under-load --tcp -i $GUEST_IP -p 11111 \
  -t 99999 --mps=2000 --full-rtt > runs/hp4_sockperf_latency.txt 2>&1 &
GEN=$!
sleep 10  # let load stabilize
echo "Starting HP-4 at $(date)"
./run_cell.sh hp4_txn2000 300
kill $GEN 2>/dev/null || true; wait $GEN 2>/dev/null || true
echo "HP-4 done at $(date)"

# ---------- HP-5: load sweep ----------
echo ""
echo "===== HP-5: load sweep ====="
for mps in 200 1000 2000 5000 10000; do
  echo "--- HP-5 @ ${mps} mps ---"
  # Restart sockperf server (clean state)
  $SSHCMD 'pkill sockperf || true; sleep 1; nohup sockperf server --tcp -i 0.0.0.0 -p 11111 </dev/null >/dev/null 2>&1 &'
  sleep 3
  taskset -c 9,11 sockperf under-load --tcp -i $GUEST_IP -p 11111 \
    -t 99999 --mps=$mps --full-rtt > "runs/hp5_txn${mps}_sockperf_latency.txt" 2>&1 &
  GEN=$!
  sleep 10
  echo "Starting HP-5 @ ${mps} mps at $(date)"
  ./run_cell.sh "hp5_txn${mps}" 300
  kill $GEN 2>/dev/null || true; wait $GEN 2>/dev/null || true
  echo "HP-5 @ ${mps} mps done at $(date)"
done

# ---------- HP-6: bursty vs steady at low load (500 mps) ----------
echo ""
echo "===== HP-6: steady vs bursty @ 500 mps ====="

# Steady
echo "--- HP-6 steady ---"
$SSHCMD 'pkill sockperf || true; sleep 1; nohup sockperf server --tcp -i 0.0.0.0 -p 11111 </dev/null >/dev/null 2>&1 &'
sleep 3
taskset -c 9,11 sockperf under-load --tcp -i $GUEST_IP -p 11111 \
  -t 99999 --mps=500 --full-rtt > runs/hp6_steady500_sockperf_latency.txt 2>&1 &
GEN=$!
sleep 10
echo "Starting HP-6 steady at $(date)"
./run_cell.sh hp6_steady500 300
kill $GEN 2>/dev/null || true; wait $GEN 2>/dev/null || true
echo "HP-6 steady done at $(date)"

# Bursty (Poisson)
echo "--- HP-6 bursty ---"
python3 poisson.py 500 4200 64 > runs/poisson_500.csv  # enough for all reps
$SSHCMD 'pkill sockperf || true; sleep 1; nohup sockperf server --tcp -i 0.0.0.0 -p 11111 </dev/null >/dev/null 2>&1 &'
sleep 3
taskset -c 9,11 sockperf playback --tcp -i $GUEST_IP -p 11111 \
  --data-file=runs/poisson_500.csv --full-rtt > runs/hp6_bursty500_sockperf_latency.txt 2>&1 &
GEN=$!
sleep 10
echo "Starting HP-6 bursty at $(date)"
./run_cell.sh hp6_bursty500 300
kill $GEN 2>/dev/null || true; wait $GEN 2>/dev/null || true
echo "HP-6 bursty done at $(date)"

# Cleanup
$SSHCMD 'pkill sockperf' 2>/dev/null || true
echo ""
echo "=== HP-4/5/6 run finished at $(date) ==="
echo "Log: $LOG"
echo "Parse: python3 parse_runs.py runs > results.csv"
