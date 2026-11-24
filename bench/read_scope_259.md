# Issue #259: internal read transaction on single-row reads

## Decision and scope

Keep the change: public reads that issue more than one statement now run in
one internal read transaction when no caller transaction is open. The issue
asked to measure the cost on single-row reads before keeping it. None of the
wrapped single-row reads got slower beyond noise, and they took 4–42% less
time. The saving is larger in rollback-journal mode, where each statement
outside a transaction otherwise takes and releases its own shared lock and
re-checks the file change counter. Reads that issue one statement are not
wrapped and are unchanged. `kvGetMany` with one key is also one statement, so
it skips the transaction; the first measurement, which wrapped it, cost
+1.5 µs per call (+6.5% rollback, +17.5% WAL).

## Method

- Baseline: `1042c4f` (issue #258). Candidate: this change. Both built from the
  same harness (`bench/read_scope_259.zig`, `zig build build-read-scope-259`)
  with `-Doptimize=ReleaseFast`.
- Zig 0.17.0, SQLite 3.53.4, Zova 1.5.0 (format 14). Linux x86-64, Intel
  i7-6700HQ. Database files on tmpfs, so no device I/O is measured.
- One fresh file database per process, seeded with 1,000 8-dimension f32
  vectors, a 12-byte object, a two-node graph with one edge, and one KV entry.
  Seeding is excluded. Each measurement is the mean of 20,000 calls.
- One warmup run per binary, then 7 trials per journal mode, alternating order
  (baseline first on odd trials, candidate first on even). No samples
  discarded. Median and MAD are over the 7 trial means, not per-call
  percentiles.
- `kv_get_unwrapped` (one statement, not wrapped) and
  `empty_deferred_transaction` (`begin` + `commit` with no statement) are
  controls.

## Results

Microseconds per call.

| Journal | Read | Baseline median | Candidate median | Change | Baseline MAD | Candidate MAD |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| delete | getVector | 50.643 | 33.317 | −34.2% | 0.157 | 0.280 |
| delete | hasVector | 48.882 | 31.854 | −34.8% | 0.423 | 0.172 |
| delete | getObject (12 bytes) | 55.255 | 39.824 | −27.9% | 0.575 | 0.181 |
| delete | kvGetMany (1 key) | 23.255 | 23.136 | −0.5% | 0.169 | 0.198 |
| delete | graphNeighbors (1 edge) | 66.371 | 51.173 | −22.9% | 0.515 | 0.391 |
| delete | graphDegree | 33.509 | 19.515 | −41.8% | 0.062 | 0.070 |
| delete | kvGet (control) | 16.479 | 16.541 | +0.4% | 0.071 | 0.028 |
| delete | empty transaction (control) | 0.960 | 0.982 | +2.3% | 0.001 | 0.010 |
| wal | getVector | 19.974 | 17.536 | −12.2% | 0.200 | 0.232 |
| wal | hasVector | 18.929 | 16.501 | −12.8% | 0.217 | 0.302 |
| wal | getObject (12 bytes) | 25.213 | 23.528 | −6.7% | 0.112 | 0.069 |
| wal | kvGetMany (1 key) | 8.561 | 8.768 | +2.4% | 0.119 | 0.048 |
| wal | graphNeighbors (1 edge) | 35.719 | 34.269 | −4.1% | 0.680 | 0.341 |
| wal | graphDegree | 8.729 | 6.164 | −29.4% | 0.102 | 0.041 |
| wal | kvGet (control) | 4.202 | 4.225 | +0.5% | 0.014 | 0.031 |
| wal | empty transaction (control) | 0.958 | 0.969 | +1.1% | 0.007 | 0.016 |

`kvGetMany (1 key)` runs the same code in both builds after the one-key skip;
its +2.4% in WAL is within two MADs of the baseline.

## Not measured

- Device-backed files. Reads here hit no device either way; a lock held for a
  whole call instead of one statement could matter more on network or slow
  filesystems, which WAL does not support anyway.
- Contention: in rollback-journal mode a writer's commit now waits for a whole
  read call rather than for one statement of it.
