#!/usr/bin/env python3
"""Summarize issue #100 scope audit timing and trace counters."""
import re
import statistics
import sys
from collections import defaultdict

PAIR = re.compile(r"([a-z_0-9]+)=([A-Za-z0-9_.-]+)")

def load(path):
    rows = defaultdict(list)
    for line in open(path):
        if not line.startswith(("baseline", "candidate")):
            continue
        variant = line.split()[0]
        fields = dict(PAIR.findall(line))
        key = (variant, fields.get("scope", "?"), fields.get("store", "?"), fields.get("op", "?"))
        rows[key].append(fields)
    return rows

def med(items, key):
    return statistics.median(float(item[key]) for item in items)

def pct(base, candidate):
    return (candidate / base - 1.0) * 100.0

def main(path):
    rows = load(path)
    print("scope   store  op                 base_p50  cand_p50  d50%  base_p95  cand_p95  d95%  trace(stmt graph node edge object_meta manifest)")
    for scope in ("graph", "object"):
        for store in ("main", "bound"):
            ops = sorted({key[3] for key in rows if key[1] == scope and key[2] == store})
            for op in ops:
                base = rows[("baseline", scope, store, op)]
                cand = rows[("candidate", scope, store, op)]
                bp50, cp50 = med(base, "p50_us"), med(cand, "p50_us")
                bp95, cp95 = med(base, "p95_us"), med(cand, "p95_us")
                trace = cand[-1]
                print(f"{scope:7} {store:6} {op:18} {bp50:8.2f} {cp50:8.2f} {pct(bp50,cp50):+6.2f}"
                      f" {bp95:8.2f} {cp95:8.2f} {pct(bp95,cp95):+6.2f}"
                      f" {trace['traced_statements']} {trace['graph_keys']} {trace['node_resolutions']}"
                      f" {trace['edge_type_resolutions']} {trace['object_metadata']} {trace['object_manifest']}")
    print("\nScope audit conclusion: no production data cache or public read session was added.")
    print("Trace counters are per complete operation after warmup; any repeated rows shown are adjacency/manifest work, not repeated metadata identity resolution.")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "trials.log")
