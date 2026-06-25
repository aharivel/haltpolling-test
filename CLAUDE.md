# CLAUDE.md — KVM Halt-Polling Power/Latency Investigation

> Handoff brief for Claude Code. This file is self-contained: project context, platform,
> all harness scripts, the ticket ladder (HP-1→HP-6), and pass/fail rules. Continue the
> work from here. Where a script is given, create it as a real file in the repo and keep
> results under `runs/`.

---

## 1. What this is

Independent reproduction and **challenge** of an internal lab report that recommends
**disabling KVM halt polling** (`KVM-HP`) in production to save power. The report claimed
~11 W package savings, "no meaningful latency impact," and ~\$53/server/yr.

We are not trying to confirm or reject it wholesale. We are establishing **where the claim
holds and where it breaks** — specifically the load band, arrival pattern, and measurement
boundary the savings are real at, and the latency cost paid for them.

**Core tradeoff under test:** halt polling spins the host CPU (keeps it in C0) for up to
`halt_poll_ns` ns before blocking an idle vCPU, trading host power for lower wakeup latency.
Disabling it lets cores reach deep C-states sooner (saves power) at the cost of wakeup
latency/jitter — *but only on vCPUs that actually halt*. The power-saving regime and the
latency-risk regime are the same regime (idle/bursty), which is the crux of the whole
investigation.

---

## 2. Platform (verified facts — do not re-assume)

- **Host:** `panther04`, dual-socket **Intel Xeon E5-2630 v3** (Haswell-EP), 8C/16T per
  socket, 85 W TDP/socket, **SMT ON**, **pre-HWP** (no Speed Shift — P-states are classic
  `intel_pstate`, governed by the OS, not hardware).
- **OS:** CentOS Stream 9. Virt stack: QEMU/KVM + libvirt.
- **Power tool:** `power_monitor.py` (user's own) emits IPMI system watts + RAPL pkg0/pkg1,
  e.g. `IPMI: 99.00W | RAPL pkg0: 22.60W | pkg1: 23.65W` at 1 s interval.
- **Idle reference:** ~25 W/package, ~99 W at IPMI → roughly half the system draw is
  *outside* the packages (DRAM/fans/PSU). This makes RAPL→IPMI attenuation a first-class
  question (H5): package savings will dilute heavily at the wall.

Implications baked into the plan:
- SMT sibling C6 gating is **live** (a core reaches C6 only when *both* HT threads idle).
- No HWP BIOS knob to manage.
- C-state exit latencies must be **read from sysfs**, not assumed.

---

## 3. The independent variable

`halt_poll_ns ∈ {200000 (default/"on"), 0 ("off")}`, toggled at runtime — no reboot:

```bash
cat /sys/module/kvm/parameters/halt_poll_ns     # 200000 = default 200µs
echo 0 > /sys/module/kvm/parameters/halt_poll_ns # disable arm
```

---

## 4. Hypotheses

| ID | Hypothesis | Predicted signature | Falsified if |
|----|------------|---------------------|--------------|
| **H1** | Savings exist only below the package power cap / vCPU-saturation point; as load rises, ΔPower → 0. | on/off power curves converge at high load. | meaningful ΔPower persists when saturated/TDP-capped. |
| **H2** | Mean latency invariant to HP; **tail** (p99.9/max) degrades with HP off, worst at **low/bursty** load. | Δmean≈0; Δp99.9 grows with longer/burstier gaps. | tail unchanged under bursty low load, or mean shifts. |
| **H3** | ΔPower is mechanistic: scales with reclaimed poll-ns and ΔPkg%pc6. | per-run ΔPower correlates with `(success_ns+fail_ns)` and C6 gain. | power drops with no residency gain (artifact). |
| **H4** | Negative control: a never-halting busy-poll vCPU shows null ΔPower and null Δlatency. | `halt_exits/s≈0`; deltas in noise. | any real delta on a non-halting workload (rig confounded). |
| **H5** | Package (RAPL) savings are **attenuated at the IPMI boundary** by DRAM/fans/PSU. | ΔIPMI < ΔRAPL. | ΔIPMI ≈ ΔRAPL (no dilution). |

H5 is an **analysis cut** over HP-4/5/6 data (the harness logs both boundaries every run),
not a separate experiment.

---

## 5. Ground rules that prevent bad data

1. **One VM running at a time.** KVM debugfs halt counters are **global** — a second guest
   pollutes them. `virsh list --all` before every session; only the test VM up.
2. **Pin the VM to one socket** so RAPL `pkg0` is the clean signal and `pkg1` is a reference.
3. **Generator off the measured socket** (far-socket / external) so its vhost/virtio threads
   don't land in the package under measurement.
4. **Randomize arm order**, N≥5 reps, 60 s warmup, **thermal-settle between runs** (wait for
   `CoreTmp` back to baseline — 1U thermal hysteresis aliases into the IV otherwise).
5. **Guest-side polling confound:** inside guest, `cat /sys/devices/system/cpu/cpuidle/current_driver`.
   If `cpuidle-haltpoll`, boot guest with `cpuidle_haltpoll.force=0` so only the host IV moves.
6. A difference only counts if **95% CIs don't overlap**.

---

## 6. SUT config lock (run once, re-verify each session)

```bash
modprobe msr                          # turbostat needs it
# BIOS (via iDRAC/Redfish/racadm): System Profile = Custom/OS control;
#   C-States Enabled; C1E Enabled; Logical Processor (HT) Enabled.
#   Turbo: OFF for clean-attribution arm, ON for realistic arm — run & report both.
cat /sys/devices/system/cpu/cpuidle/current_driver        # expect intel_idle
# enumerate C-states + EXIT LATENCIES (record these — used in HP-6 analysis):
for s in /sys/devices/system/cpu/cpu0/cpuidle/state*/; do
  printf '%-6s lat=%-5sus resid=%sus\n' "$(cat $s/name)" "$(cat $s/latency)" "$(cat $s/residency)"
done
# clean-attribution arm:
echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo
cpupower frequency-set -g performance
systemctl stop irqbalance
# core isolation (or isolcpus/nohz_full/rcu_nocbs on cmdline):
tuned-adm profile cpu-partitioning
```

**Pin the test VM to socket 0** (adjust core IDs to your topology; assumes node0 = cores 0-7):

```bash
DOM=halt-test
virsh vcpupin    $DOM 0 2
virsh vcpupin    $DOM 1 3
virsh emulatorpin $DOM 8-15            # housekeeping on the OTHER socket
virsh numatune   $DOM --mode strict --nodeset 0
```

---

## 7. The measurement harness

### 7.1 `measure.sh` — capture one synced window

Create as `measure.sh`. Workload must already be running and warmed up before calling it.

```bash
#!/usr/bin/env bash
# measure.sh <label> <hp_ns> <duration_s>
set -euo pipefail
LABEL=$1; HPNS=$2; DUR=${3:-300}
KVMD=/sys/kernel/debug/kvm; OUT=runs/$LABEL; mkdir -p "$OUT"

echo "$HPNS" > /sys/module/kvm/parameters/halt_poll_ns
echo "halt_poll_ns=$(cat /sys/module/kvm/parameters/halt_poll_ns)" > "$OUT/arm"

read_halt(){ for f in halt_exits halt_attempted_poll halt_successful_poll halt_poll_invalid \
  halt_poll_success_ns halt_poll_fail_ns halt_wait_ns; do
  printf '%s %s\n' "$f" "$(cat "$KVMD/$f")"; done; }

read_halt > "$OUT/halt.t0"
python power_monitor.py > "$OUT/power.csv" 2>&1 & PM=$!
# --Summary => one system-summary row per interval (easy to parse):
turbostat --interval 5 --quiet --Summary \
  --show PkgWatt,RAMWatt,Busy%,Bzy_MHz,CPU%c1,CPU%c6,Pkg%pc2,Pkg%pc6,CoreTmp \
  --out "$OUT/turbostat.txt" & TS=$!

sleep "$DUR"
kill -INT "$PM" 2>/dev/null || true
kill "$TS" 2>/dev/null || true
wait 2>/dev/null || true

read_halt > "$OUT/halt.t1"
join "$OUT/halt.t0" "$OUT/halt.t1" | awk '{printf "%-26s %d\n",$1,$3-$2}' > "$OUT/halt.delta"
echo "done -> $OUT  (window=${DUR}s, halt_poll_ns=$HPNS)"
```

### 7.2 `run_cell.sh` — randomized on/off × N reps at the current load

```bash
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
```

### 7.3 `poisson.py` — bursty arrival file for HP-6

```python
#!/usr/bin/env python3
# poisson.py <mean_mps> <duration_s> [msg_bytes]  -> stdout CSV for sockperf playback
import sys, random
mean = float(sys.argv[1]); dur = float(sys.argv[2])
size = int(sys.argv[3]) if len(sys.argv) > 3 else 64
t = 0.0
while t < dur:
    t += random.expovariate(mean)          # Poisson inter-arrivals
    print(f"{t:.6f},{size}")
```

### 7.4 `parse_runs.py` — collapse `runs/*/` into one CSV row per run

Create as `parse_runs.py`. Produces the analysis table (one row per measured window) with
derived `poll_success_rate`, `wasted_ns_s`, `reclaimable_ns_s`. **Note:** the
`power_monitor.py` line regex and the turbostat column parsing may need a tweak to match your
exact output formatting — adjust the two marked spots if columns come out empty.

```python
#!/usr/bin/env python3
"""Collapse runs/<label>/ dirs into one CSV row each.
Reads: arm, power.csv (IPMI/RAPL), turbostat.txt (--Summary), halt.delta
Usage: python parse_runs.py runs > results.csv
"""
import sys, os, re, glob, statistics as st

POWER_RE = re.compile(
    r"IPMI:\s*([\d.]+)\s*W.*?pkg0:\s*([\d.]+)\s*W.*?pkg1:\s*([\d.]+)\s*W", re.I)

def parse_power(path):
    ipmi, p0, p1 = [], [], []
    if not os.path.exists(path): return (None, None, None)
    for line in open(path, errors="ignore"):
        m = POWER_RE.search(line)            # <-- adjust regex if your format differs
        if m:
            ipmi.append(float(m.group(1)))
            p0.append(float(m.group(2)))
            p1.append(float(m.group(3)))
    avg = lambda xs: round(st.mean(xs), 2) if xs else None
    return avg(ipmi), avg(p0), avg(p1)

def parse_turbostat(path):
    """--Summary => header row + one data row per interval. Average requested cols."""
    if not os.path.exists(path): return {}
    rows, header = [], None
    for line in open(path, errors="ignore"):
        parts = line.split()
        if not parts: continue
        if header is None and any(c in parts for c in ("PkgWatt","Pkg%pc6","Busy%")):
            header = parts; continue          # <-- header detection
        if header and len(parts) == len(header):
            try:
                rows.append([float(x) for x in parts])
            except ValueError:
                pass
    if not header or not rows: return {}
    out = {}
    for i, name in enumerate(header):
        vals = [r[i] for r in rows]
        out[name] = round(st.mean(vals), 3)
    return out

def parse_halt(path):
    d = {}
    if not os.path.exists(path): return d
    for line in open(path):
        k, v = line.split()
        d[k] = int(v)
    return d

def parse_arm(path):
    if not os.path.exists(path): return None
    m = re.search(r"halt_poll_ns=(\d+)", open(path).read())
    return int(m.group(1)) if m else None

def main(root):
    cols = ["label","hp_ns","window_dirs",
            "ipmi_W","rapl_pkg0_W","rapl_pkg1_W",
            "PkgWatt","Pkg%pc6","CPU%c6","Bzy_MHz","CoreTmp",
            "halt_exits","poll_success_rate","success_ns","fail_ns","wait_ns",
            "reclaimable_ns","wasted_ns"]
    print(",".join(cols))
    for d in sorted(glob.glob(os.path.join(root, "*"))):
        if not os.path.isdir(d): continue
        label = os.path.basename(d)
        hp = parse_arm(os.path.join(d, "arm"))
        ipmi, p0, p1 = parse_power(os.path.join(d, "power.csv"))
        ts = parse_turbostat(os.path.join(d, "turbostat.txt"))
        h = parse_halt(os.path.join(d, "halt.delta"))
        att = h.get("halt_attempted_poll", 0)
        suc = h.get("halt_successful_poll", 0)
        sns = h.get("halt_poll_success_ns", 0)
        fns = h.get("halt_poll_fail_ns", 0)
        wns = h.get("halt_wait_ns", 0)
        rate = round(suc/att, 4) if att else 0.0
        row = [label, hp, 1,
               ipmi, p0, p1,
               ts.get("PkgWatt"), ts.get("Pkg%pc6"), ts.get("CPU%c6"),
               ts.get("Bzy_MHz"), ts.get("CoreTmp"),
               h.get("halt_exits"), rate, sns, fns, wns,
               sns+fns, fns]
        print(",".join("" if v is None else str(v) for v in row))

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "runs")
```

Aggregate to mean ± CI per (ticket, hp_ns) cell at analysis time (pandas groupby on the
`label` prefix, or hand it back to Claude for the stats + plots).

---

## 8. Ticket ladder — 1 test = 1 ticket, simplest first

Each ticket adds exactly **one** new variable over the previous. HP-1/2/3 need no workload
tooling; HP-4 introduces the load generator.

### HP-1 · Idle host baseline, no VM
Establishes the **noise floor** every later comparison is judged against.
```bash
virsh list --all                 # confirm NO guest running
./run_cell.sh hp1_idlehost 300   # hp on/off is irrelevant here but harmless
```
Measure: idle RAPL/IPMI, Pkg%pc6, **run-to-run variance**.
**AC:** variance quantified → defines the CI noise band. Adds: nothing (proves harness on trivial case).

### HP-2 · Single idle VM, HP on vs off
Simplest real halt-polling test; gives the **maximum idle saving**.
```bash
virsh start halt-test            # 2 vCPU, idle guest (halts constantly)
# (apply §6 pinning)
./run_cell.sh hp2_idlevm 300
```
Measure: ΔRAPL, ΔIPMI, ΔPkg%pc6, `poll_success_rate`, `wasted_ns`.
**AC:** clean ΔPower with matching C6-residency gain (mechanism visible). Adds: the IV.

### HP-3 · Busy-poll control VM, HP on vs off  ← **GATE**
Negative control: vCPU never halts, so HP must do nothing.
```bash
# inside guest: make each vCPU spin so it never issues HLT
#   for c in 0 1; do taskset -c $c sh -c 'while :; do :; done' & done
./run_cell.sh hp3_busypoll 300
```
Measure: ΔPower, Δlatency, `halt_exits/s`.
**AC:** `halt_exits/s ≈ 0` AND both ΔPkgWatt & ΔIPMI **inside the HP-1 noise band**.
If not → rig confounded, **stop and fix before trusting HP-2/4/5/6.** Adds: the contrast
(HP-2 max-halt vs HP-3 zero-halt bracket the entire effect).

### HP-4 · Single-point transactional load, HP on vs off
First ticket needing the load harness. vCPU now halts *between* requests.
```bash
# guest:  sockperf server --tcp -i 0.0.0.0 -p 11111
# host (far socket): pin generator off the measured package
taskset -c 8-9 sockperf under-load --tcp -i <guest_ip> -p 11111 \
  -t 360 --mps=2000 --full-rt-distribution &
./run_cell.sh hp4_txn2000 300
```
Measure: ΔPower + p50/p99/p99.9 at one realistic point.
**AC:** deltas with CIs at a single load. Adds: a real workload (one point, steady arrival).

### HP-5 · Load sweep → convergence knee (H1)
```bash
for mps in 200 1000 2000 5000 10000; do
  taskset -c 8-9 sockperf under-load --tcp -i <guest_ip> -p 11111 -t 99999 --mps=$mps &
  GEN=$!; sleep 5
  ./run_cell.sh hp5_txn${mps} 300
  kill $GEN
done
```
Plot PkgWatt(on) vs PkgWatt(off) against achieved throughput; mark where they converge.
**Note:** a light 2-vCPU reflector likely **saturates the vCPU** (halting stops → HP
irrelevant) *before* it pulls 85 W (RAPL cap). If you specifically want the TDP-limited
regime the original doc hit, scale the guest up (more vCPUs + rate, or add CPU-bound co-load)
until `PkgWatt≈85` and `Bzy_MHz` clamps. **Label which knee you actually reached.** Adds: load dimension.

### HP-6 · Bursty vs steady at low load (H2 — SLA-critical)
Same mean rate, two arrival shapes, at a **low** load point.
```bash
# steady:
taskset -c 8-9 sockperf under-load --tcp -i <guest_ip> -p 11111 -t 360 --mps=500 &
./run_cell.sh hp6_steady500 300
# bursty (Poisson):
python3 poisson.py 500 360 64 > poisson.csv
taskset -c 8-9 sockperf playback --tcp -i <guest_ip> -p 11111 \
  --data-file=poisson.csv --full-rt-distribution &
./run_cell.sh hp6_bursty500 300
```
Compare **Δp99.9 / Δmax**, HP on vs off, steady vs bursty. Expectation: means track across
all four; the tail diverges (HP-off worse) under **bursty + low load**, because the first
packet after each idle gap eats the full **C6 exit latency** (the µs you recorded in §6) +
reschedule that polling was hiding. Cross-check `halt_poll_fail_hist`: gaps >200 µs push
fails into the top buckets. Adds: arrival-pattern dimension + tail stats.

---

## 9. Corner cases (become their own tickets after HP-6, roughly this order)

- **SMT sibling C6 gating** (LIVE on Haswell): busy vCPU + idle vCPU on sibling threads of
  one core → idle one can't reach core C6. Compare vs same vCPUs on different cores. Watch `CPU%c6`.
- **Package PC6 gating by placement:** scatter one busy VM across many cores vs consolidate;
  watch `Pkg%pc6`. Explains large-vs-zero per-package saving for identical work.
- **Inter-arrival sweep around 200 µs:** sweep idle gap 50 µs→2 ms; read `halt_poll_*_hist`.
  Non-monotonic region is gaps *near* the poll window.
- **Overcommit / noisy neighbor:** vCPUs > pCPUs. HP-on = not yielding → steals from
  co-tenants; disabling may *improve* neighbor latency/power. Can flip the conclusion's sign.
  (Note: violates the one-VM rule, so use per-VM `KVM_CAP_HALT_POLL` or accept global counters
  are meaningless here and rely on power+latency only.)
- **Governor misprediction:** with HP off, look at the C-state *residency distribution*, not
  aggregate idle%. Short-idle mispredict → shallow C1, little power moved despite "idle% up."
- **Adaptive grow/shrink under phase change:** alternate bursty↔idle; expect hysteresis a
  steady test won't show.

---

## 10. Pass / fail (fill ⟨⟩ from SLA + fleet economics before running)

Differences require **non-overlapping 95% CIs (N≥5)**.

**DISABLE** if all hold in the production load band:
- ΔRAPL ≥ ⟨W_min_pkg⟩, and ΔIPMI ≥ ⟨W_min_sys⟩ (survives to the wall — H5), and
- Δp99.9 ≤ ⟨lat_budget_us⟩ **under bursty arrivals at the lowest in-band load**, and
- the saving appears at loads the server actually runs at.

**KEEP** if any: tail regresses beyond ⟨lat_budget_us⟩ at any in-band load; or package saving
doesn't survive to IPMI; or saving only appears in a rarely-occupied regime.

**TUNE** (lower `halt_poll_ns`, not zero) if `poll_success_rate` is high but `wasted_ns` is
also high → shrink the window, re-test the chosen value as a third arm.

**Financial gate (sanity):**
`annual_$ = ΔIPMI_W × 8760 × ⟨$/kWh⟩ × ⟨PUE⟩ / 1000`, evaluated at the **load-weighted
average**, not idle. Publish the formula + inputs (the reference \$53 did not). Must beat the
per-server amortized cost of validation + monitoring + risk at fleet scale.

---

## 11. Headline deliverables

1. **ΔPower vs utilization** (RAPL and IPMI overlaid), TDP/saturation knee marked → H1, H5.
2. **Δp99.9 vs arrival gap** (steady vs bursty) → H2.
3. Per-hypothesis verdict table: confirmed / falsified / inconclusive + the regime it applies to.

These two charts are exactly what the original writeup lacked.

---

## 12. Suggested repo layout

```
.
├── CLAUDE.md                 # this file
├── measure.sh
├── run_cell.sh
├── poisson.py
├── parse_runs.py
├── power_monitor.py          # existing
├── config/sut-baseline.txt   # §6 dump, per session
└── runs/                     # one dir per measured window
```

**Next action for Claude Code:** create the four scripts above, run §6 config lock, then
execute HP-1 → HP-2 → HP-3 (gate). Do not proceed past HP-3 until the negative control passes.
