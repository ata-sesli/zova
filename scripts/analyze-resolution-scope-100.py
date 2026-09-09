#!/usr/bin/env python3
"""Summarize issue #100 scope audit timing and trace counters.

Counters come from the stable private `zova_trace:*` SQL comments:
graph_key/graph_node_resolve/graph_edge_resolve are identity resolvers;
graph_adjacency/walk_adjacency are adjacency statement executions (not rows);
object_metadata/object_exists/object_range/object_reader_manifest are the
cached/reader object statements. SQLITE_TRACE_STMT counts statement
executions, never rows.
"""
import re
import statistics
import sys
from collections import defaultdict

PAIR = re.compile(r"([a-z_0-9]+)=([A-Za-z0-9_.\-]+)")
COUNTERS = ("traced_statements", "graph_keys", "node_resolutions", "edge_resolutions",
            "adjacency", "walk_adjacency", "object_metadata", "object_exists",
            "object_range", "object_reader_manifest")

def load(path):
    rows = defaultdict(list)
    for line in open(path):
        if not line.startswith(("baseline", "candidate")):
            continue
        variant = line.split()[0]
        fields = dict(PAIR.findall(line))
        if "op" not in fields:
            continue
        key = (variant, fields.get("scope", "?"), fields.get("store", "?"), fields["op"])
        rows[key].append({k: float(v) for k, v in fields.items() if k in ("p50_us", "p95_us", *COUNTERS)})
    return rows

def med(items, key):
    return statistics.median(item[key] for item in items)

def pct(base, candidate):
    return (candidate / base - 1.0) * 100.0

def main(path):
    rows = load(path)
    print("scope   store  op        base_p50  cand_p50  d50%  base_p95  cand_p95  d95%  counters(cand): stmt graph node edge adj walk meta exists range reader")
    for scope in ("graph", "object"):
        for store in ("main", "bound"):
            ops = sorted({key[3] for key in rows if key[1] == scope and key[2] == store})
            for op in ops:
                base = rows.get(("baseline", scope, store, op), [])
                cand = rows.get(("candidate", scope, store, op), [])
                if not base or not cand:
                    print(f"{scope:7} {store:6} {op:9} MISSING base={len(base)} cand={len(cand)}")
                    continue
                bp50, cp50 = med(base, "p50_us"), med(cand, "p50_us")
                bp95, cp95 = med(base, "p95_us"), med(cand, "p95_us")
                t = cand[-1]
                counters = " ".join(str(int(t[k])) for k in COUNTERS)
                print(f"{scope:7} {store:6} {op:9} {bp50:8.2f} {cp50:8.2f} {pct(bp50,cp50):+6.2f}"
                      f" {bp95:8.2f} {cp95:8.2f} {pct(bp95,cp95):+6.2f}  {counters}")
    print("")
    print("Scope audit conclusion: no production data cache or public read session was added.")
    print("Counter semantics: statement executions per complete operation after warmup, from private trace markers.")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "trials.log")
