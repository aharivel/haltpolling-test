#!/usr/bin/env bash
# run_hp1-3.sh — run HP-1, HP-2, HP-3 back-to-back, unattended
# Run as root from repo dir. Use tmux/screen.
set -euo pipefail

GUEST_IP=192.168.122.244
LOG=runs/hp1-3_$(date +%Y%m%d_%H%M%S).log

exec > >(tee -a "$LOG") 2>&1
echo "=== HP-1/2/3 run started at $(date) ==="

# ---------- HP-1: idle host, no VM ----------
echo ""
echo "===== HP-1: idle host baseline (no VM) ====="
virsh shutdown halt-test 2>/dev/null || true
echo "Waiting for VM to shut off..."
for i in $(seq 1 60); do
  state=$(virsh domstate halt-test 2>/dev/null || echo "shut off")
  [[ "$state" == "shut off" ]] && break
  sleep 1
done
virsh list --all
echo "Starting HP-1 at $(date)"
./run_cell.sh hp1_idlehost 300
echo "HP-1 done at $(date)"

# ---------- HP-2: idle VM, HP on vs off ----------
echo ""
echo "===== HP-2: idle VM ====="
virsh start halt-test
echo "Waiting 90s for VM boot + settle..."
sleep 90
# Re-apply pinning (lost on restart)
virsh vcpupin halt-test 0 2
virsh vcpupin halt-test 1 4
virsh vcpupin halt-test 2 6
virsh vcpupin halt-test 3 8
virsh vcpupin halt-test 4 10
virsh vcpupin halt-test 5 12
virsh vcpupin halt-test 6 14
virsh vcpupin halt-test 7 18
virsh emulatorpin halt-test 3,5,7
echo "Pinning applied. Starting HP-2 at $(date)"
./run_cell.sh hp2_idlevm 300
echo "HP-2 done at $(date)"

# ---------- HP-3: busy-poll negative control (GATE) ----------
echo ""
echo "===== HP-3: busy-poll negative control ====="
echo "Starting spinners on all 8 guest vCPUs..."
ssh -o StrictHostKeyChecking=no root@$GUEST_IP \
  'for c in 0 1 2 3 4 5 6 7; do taskset -c $c sh -c "while :; do :; done" & done'
sleep 10  # let spinners stabilize
echo "Starting HP-3 at $(date)"
./run_cell.sh hp3_busypoll 300
echo "HP-3 done at $(date)"

# Cleanup: kill spinners
ssh -o StrictHostKeyChecking=no root@$GUEST_IP 'killall sh' 2>/dev/null || true
echo ""
echo "=== HP-1/2/3 run finished at $(date) ==="
echo "Log: $LOG"
echo "Parse results: python3 parse_runs.py runs > results.csv"
