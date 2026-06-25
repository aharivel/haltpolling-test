#!/usr/bin/env bash
# setup-isolation.sh — configure CPU isolation + tuned profile for halt-polling tests
# Run as root on panther04. REQUIRES REBOOT after.
set -euo pipefail

# Housekeeping: CPUs 0,16 (node0 core0) + 1,17 (node1 core0)
# Isolated:    2-15,18-31 (everything else)
ISOLATED="2-15,18-31"

echo "isolated_cores=$ISOLATED" > /etc/tuned/cpu-partitioning-powersave-variables.conf
echo "max_power_state=C6|170" >> /etc/tuned/cpu-partitioning-powersave-variables.conf

tuned-adm profile cpu-partitioning-powersave

grubby --update-kernel ALL --args "isolcpus=$ISOLATED nohz_full=$ISOLATED rcu_nocbs=$ISOLATED"

echo ""
echo "Done. Reboot required."
echo "After reboot verify:"
echo "  cat /proc/cmdline | grep -o 'isolcpus=[^ ]*'"
echo "  cat /sys/devices/system/cpu/isolated"
echo ""
