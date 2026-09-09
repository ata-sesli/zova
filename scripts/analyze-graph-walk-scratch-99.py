#!/usr/bin/env python3
"""Summarize issue #99 trials.log (three trials per variant/store)."""
import statistics
import sys
import re
from collections import defaultdict

PAIR = re.compile(r"([a-z_0-9]+)=([A-Za-z0-9_.-]+)")

def load(path):
    rows = defaultdict(list)
    for line in open(path):
        if not line.startswith(("baseline", "candidate")):
            continue
        variant = line.split()[0]
        f = dict(PAIR.findall(line))
        key = (variant, f.get("store", "?"), f.get("limit", "?"))
        rows[key].append(f)
    return rows

def med(rows, key):
    return statistics.median(float(row[key]) for row in rows)

def pct(base, candidate):
    return (candidate / base - 1.0) * 100.0

def main(path):
    rows = load(path)
    print("store limit              base       cand    delta%   base_p95   cand_p95   allocs  peak_bytes  scratch_bytes")
    deltas = []
    for store in ("main", "bound"):
        for limit in ("32", "512", "10000", "32_after_large"):
            base = rows[("baseline", store, limit)]
            cand = rows[("candidate", store, limit)]
            metric = "total_us" if limit == "10000" else "p50_us"
            b = med(base, metric)
            c = med(cand, metric)
            d = pct(b, c)
            deltas.append((store, limit, d))
            if limit == "10000":
                bp = cp = float("nan")
            else:
                bp, cp = med(base, "p95_us"), med(cand, "p95_us")
            print(f"{store:5} {limit:15} {b:10.3f} {c:10.3f} {d:+8.2f} {bp:10.3f} {cp:10.3f}"
                  f" {med(base, 'allocs'):7.0f}->{med(cand, 'allocs'):.0f}"
                  f" {med(base, 'peak_bytes'):10.0f}->{med(cand, 'peak_bytes'):.0f}"
                  f" {med(cand, 'scratch_retained_bytes'):11.0f}")
    best = min(d for _, _, d in deltas)
    worst = max(d for _, _, d in deltas if d != min(d for _, _, d in deltas))
    print(f"best median improvement: {best:+.2f}%")
    print(f"worst adjacent median: {worst:+.2f}%")
    print("common retention gate: " + ("PASS" if best <= -5 and worst <= 5 else "FAIL"))

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "trials.log")
