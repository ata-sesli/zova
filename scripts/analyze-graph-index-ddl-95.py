#!/usr/bin/env python3
"""Summarize issue #95 trials.log: median/MAD for writes, median p50/p95 for reads."""
import re
import statistics
import sys
from collections import defaultdict

PAIR = re.compile(r"([a-z_0-9]+)=([A-Za-z0-9_.]+)")


def load(path):
    writes = defaultdict(list)
    reads = defaultdict(list)
    for line in open(path):
        if not line.startswith(("baseline", "candidate")):
            continue
        variant = line.split()[0]
        fields = {}
        for key, value in PAIR.findall(line):
            fields[key] = value
        if "op" in fields:
            key = (fields.get("store", "?"), fields.get("edges", "?"), fields.get("mode", "?"), fields["op"])
            reads[(variant,) + key].append((float(fields["p50_us"]), float(fields["p95_us"])))
        elif "median_ms" in fields:
            key = (fields.get("store", "?"), fields.get("edges", "?"), fields.get("mode", "?"))
            writes[(variant,) + key].append((
                float(fields["median_ms"]),
                float(fields["mad_ms"]),
                int(float(fields["stmts"])),
                int(float(fields["create_index"])),
                int(float(fields["probe"])),
            ))
    return writes, reads


def median(values):
    return statistics.median(values)


def mad(values):
    centre = statistics.median(values)
    return statistics.median([abs(v - centre) for v in values])


def pct_change(base, cand):
    if base == 0:
        return float("nan")
    return (cand - base) / base * 100.0


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "trials.log"
    writes, reads = load(path)

    # A partial matrix cannot establish the retention gate. Require the three
    # measured trials emitted by the runner for every variant and workload.
    for variant in ("baseline", "candidate"):
        for store in ("main", "bound"):
            for edges in ("1", "16", "1024"):
                for mode in ("steady", "dropped"):
                    key = (variant, store, edges, mode)
                    if len(writes.get(key, [])) != 3:
                        raise SystemExit(f"Incomplete write matrix: {key}; expected 3 trials")
                    for op in ("neighbors_untyped", "neighbors_typed", "degree", "walk_depth2"):
                        if len(reads.get(key + (op,), [])) != 3:
                            raise SystemExit(f"Incomplete read matrix: {key + (op,)}; expected 3 trials")

    print("== WRITE: per-batch median (ms) across 3 trials, 3 trials per variant ==")
    print(f"{'store':6} {'edges':6} {'mode':8} {'base_med':>10} {'base_mad':>9} {'cand_med':>10} {'cand_mad':>9} {'delta%':>8} {'ci_base':>8} {'ci_cand':>8} {'probe_cand':>10}")
    write_rows = []
    for store in ("main", "bound"):
        for edges in ("1", "16", "1024"):
            for mode in ("steady", "dropped"):
                b = writes.get(("baseline", store, edges, mode), [])
                c = writes.get(("candidate", store, edges, mode), [])
                if not b or not c:
                    print(f"{store:6} {edges:6} {mode:8} MISSING base={len(b)} cand={len(c)}")
                    continue
                bm, cm = median([x[0] for x in b]), median([x[0] for x in c])
                delta = pct_change(bm, cm)
                write_rows.append((store, edges, mode, bm, cm, delta))
                print(f"{store:6} {edges:6} {mode:8} {bm:10.4f} {mad([x[0] for x in b]):9.4f} "
                      f"{cm:10.4f} {mad([x[0] for x in c]):9.4f} {delta:8.2f} "
                      f"{b[0][3]:8d} {c[0][3]:8d} {c[0][4]:10d}")

    print()
    print("== READ: median of per-trial p50/p95 (us) ==")
    print(f"{'store':6} {'edges':6} {'mode':8} {'op':20} {'b_p50':>9} {'c_p50':>9} {'d50%':>7} {'b_p95':>9} {'c_p95':>9} {'d95%':>7}")
    read_rows = []
    for store in ("main", "bound"):
        for edges in ("1", "16", "1024"):
            for mode in ("steady", "dropped"):
                for op in ("neighbors_untyped", "neighbors_typed", "degree", "walk_depth2"):
                    b = reads.get(("baseline", store, edges, mode, op), [])
                    c = reads.get(("candidate", store, edges, mode, op), [])
                    if not b or not c:
                        continue
                    bp50 = median([x[0] for x in b]); cp50 = median([x[0] for x in c])
                    bp95 = median([x[1] for x in b]); cp95 = median([x[1] for x in c])
                    d50 = pct_change(bp50, cp50); d95 = pct_change(bp95, cp95)
                    read_rows.append((store, edges, mode, op, d50, d95))
                    print(f"{store:6} {edges:6} {mode:8} {op:20} {bp50:9.2f} {cp50:9.2f} {d50:7.2f} "
                          f"{bp95:9.2f} {cp95:9.2f} {d95:7.2f}")

    print()
    target = [r for r in write_rows if r[2] == "steady"]
    if target:
        best = min(r[5] for r in target)
        worst = max(r[5] for r in target)
        print(f"== GATE ==\ntarget (fresh/replay) delta range: {best:.2f}% .. {worst:.2f}% "
              f"({'PASS' if best <= -5.0 else 'FAIL'} >=5% improvement on best target)")
    if read_rows:
        worst50 = max(r[4] for r in read_rows)
        worst95 = max(r[5] for r in read_rows)
        print(f"worst read regression: p50 {worst50:+.2f}%  p95 {worst95:+.2f}% "
              f"({'PASS' if max(worst50, worst95) <= 5.0 else 'FAIL'} <=5%)")


if __name__ == "__main__":
    main()
