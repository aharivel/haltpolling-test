#!/usr/bin/env bash
# run_cell.sh <ticket_tag> <duration_s>   (workload already running)
set -euo pipefail
TAG=$1; DUR=${2:-300}
for rep in 1 2 3 4 5; do
  for hp in $(shuf -e 0 200000); do        # randomized arm order
    sleep 60                                # warmup at current load
    ./measure.sh "${TAG}_hp${hp}_r${rep}" "$hp" "$DUR"
    sleep 90                                # thermal settle
  done
done
