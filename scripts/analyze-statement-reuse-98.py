#!/usr/bin/env python3
"""Summarize issue #98 trials.log: median p50/p95 per op plus prepare/reuse counters.

Usage: python3 scripts/analyze-statement-reuse-98.py TRIALS_LOG
"""
import re
import statistics
import sys
from collections import defaultdict

PAIR = re.compile(r"([a-z_0-9]+)=([A-Za-z0-9_.\-]+)")
FLOAT = re.compile(r"([a-z_0-9]+)=(-?[0-9]+(?:\.[0-9]+)?)")


def load(path):
    rows = defaultdict(list)
    for line in open(path):
        if not line.startswith(("baseline", "candidate")):
            continue
        variant = line.split()[0]
        fields = {k: v for k, v in PAIR.findall(line)}
        floats = {k: float(v) for k, v in FLOAT.findall(line)}
        if "op" not in fields:
            continue
        key = (variant, fields.get("workload", "?"), fields.get("variant", "-"),
               fields.get("store", "?"), fields["op"])
        rows[key].append(floats)
    return rows


def median(values):
    return statistics.median(values)


def pct_change(base, cand):
    if base == 0:
        return float("nan")
    return (cand - base) / base * 100.0


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "trials.log"
    rows = load(path)

    print("== READ: median of per-trial p50/p95 (us), 3 trials per variant ==")
    print(f"{'workload':9} {'variant':14} {'store':6} {'op':18} {'b_p50':>9} {'c_p50':>9} {'d50%':>8} "
          f"{'b_p95':>9} {'c_p95':>9} {'d95%':>8}")
    deltas = []
    keys = sorted({k[1:] for k in rows})
    for workload, variant, store, op in keys:
        b = rows.get(("baseline", workload, variant, store, op), [])
        c = rows.get(("candidate", workload, variant, store, op), [])
        if not b or not c:
            print(f"{workload:9} {variant:14} {store:6} {op:18} MISSING base={len(b)} cand={len(c)}")
            continue
        bp50 = median([x["p50_us"] for x in b])
        cp50 = median([x["p50_us"] for x in c])
        bp95 = median([x["p95_us"] for x in b])
        cp95 = median([x["p95_us"] for x in c])
        d50 = pct_change(bp50, cp50)
        d95 = pct_change(bp95, cp95)
        deltas.append((workload, variant, store, op, d50, d95))
        print(f"{workload:9} {variant:14} {store:6} {op:18} {bp50:9.2f} {cp50:9.2f} {d50:8.2f} "
              f"{bp95:9.2f} {cp95:9.2f} {d95:8.2f}")

    print()
    print("== MECHANISM: cache reuse per 200-call window (candidate) ==")
    print(f"{'workload':9} {'variant':14} {'store':6} {'op':18} {'prepares':>9} {'reuses':>9} {'retained':>9} {'stmt_bytes':>11}")
    for workload, variant, store, op in keys:
        c = rows.get(("candidate", workload, variant, store, op), [])
        if not c:
            continue
        print(f"{workload:9} {variant:14} {store:6} {op:18} "
              f"{median([x['window_prepares'] for x in c]):9.0f} "
              f"{median([x['window_reuses'] for x in c]):9.0f} "
              f"{median([x['cache_retained'] for x in c]):9.0f} "
              f"{median([x['stmt_bytes'] for x in c]):11.0f}")

    print()
    print("== MEMORY: result allocations and retained bytes (median of trials) ==")
    print(f"{'workload':9} {'variant':14} {'store':6} {'op':18} {'b_allocs':>9} {'c_allocs':>9} {'b_retain':>9} {'c_retain':>9} {'b_stmtb':>9} {'c_stmtb':>9}")
    for workload, variant, store, op in keys:
        b = rows.get(("baseline", workload, variant, store, op), [])
        c = rows.get(("candidate", workload, variant, store, op), [])
        if not b or not c:
            continue
        print(f"{workload:9} {variant:14} {store:6} {op:18} "
              f"{median([x['allocs'] for x in b]):9.0f} {median([x['allocs'] for x in c]):9.0f} "
              f"{median([x['retained_bytes'] for x in b]):9.0f} {median([x['retained_bytes'] for x in c]):9.0f} "
              f"{median([x['stmt_bytes'] for x in b]):9.0f} {median([x['stmt_bytes'] for x in c]):9.0f}")

    if deltas:
        best = min(min(d50, d95) for *_rest, d50, d95 in deltas)
        worst = max(max(d50, d95) for *_rest, d50, d95 in deltas)
        print()
        print(f"== GATE ==\nbest improvement: {best:.2f}% ({'PASS' if best <= -5.0 else 'FAIL'} needs <= -5%)")
        print(f"worst regression: {worst:+.2f}% ({'PASS' if worst <= 5.0 else 'FAIL'} needs <= +5%)")


if __name__ == "__main__":
    main()
