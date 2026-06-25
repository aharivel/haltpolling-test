#!/usr/bin/env python3
# poisson.py <mean_mps> <duration_s> [msg_bytes]  -> stdout CSV for sockperf playback
import sys, random
mean = float(sys.argv[1]); dur = float(sys.argv[2])
size = int(sys.argv[3]) if len(sys.argv) > 3 else 64
t = 0.0
while t < dur:
    t += random.expovariate(mean)          # Poisson inter-arrivals
    print(f"{t:.6f},{size}")
