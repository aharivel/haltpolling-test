#!/usr/bin/env bash
# run_cell.sh <ticket_tag> <duration_s>   (workload already running)
set -euo pipefail
TAG=$1; DUR=${2:-300}
echo "[run_cell] Starting: tag=$TAG dur=${DUR}s reps=5 arms=2"
for rep in 1 2 3 4 5; do
  for hp in $(shuf -e 0 200000); do        # randomized arm order
    echo "[run_cell] rep=$rep hp=$hp — warming up 60s..."
    sleep 60                                # warmup at current load
    echo "[run_cell] rep=$rep hp=$hp — running measure.sh (${DUR}s)..."
    ./measure.sh "${TAG}_hp${hp}_r${rep}" "$hp" "$DUR"
    echo "[run_cell] rep=$rep hp=$hp — thermal settle 90s..."
    sleep 90                                # thermal settle
  done
done
echo "[run_cell] All reps done for $TAG"
