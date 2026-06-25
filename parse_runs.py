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
