# Issue #196: ObjectWriter ingest by size, not by call

## Decision

Retain size-based commits. `ObjectWriter` now buffers emitted chunks and
stores them in one transaction once 64 MiB are pending, and at `finish`. On
the streaming profile, 1 MiB writes went from 32.6 to 60.1 MB/s (1.8×), and
ingest no longer depends on the caller's write size. 64 MiB writes are about
5% slower (63.4 to 60.5 MB/s) because every chunk is now copied into the
pending buffer.

The first candidate allocated and freed one buffer per pending chunk. It lost
about 9% at 64 MiB writes: freeing a 64 MiB batch returned the pages, and the
next batch faulted them back in (131k extra minor faults per 256 MiB, +0.3 s
system time). The retained version keeps pending bytes in slabs of four
maximum-size chunks across commits. That leaves one-time faults for the first
64 MiB (+16k).

## Method

- Machine: Intel i7-6700HQ (no SHA-NI), 11 GiB RAM, Fedora 45 (Linux 7.2.15),
  btrfs with `compress=zstd:1` (the payload is incompressible).
- Zig 0.17.0, `ReleaseFast`, bundled SQLite 3.53.4, default rollback journal,
  4 KiB pages, `foreign_keys = on`, production object schema through
  `object.Database.initForPrototype`.
- Harness: `bench/object_writer_196.zig`, one 256 MiB deterministic
  pseudo-random object per sample. The timed region covers every `write` and
  `finish`; the object id is checked against SHA-256 of the payload.
- Baseline: `origin/main` at `1f3d503` with the same harness copied in.
  Candidate: the #196 branch.
- `scripts/bench-object-writer-196.sh`: per profile and write size, one warmup
  and three measured samples, alternating baseline/candidate order, a new
  database per sample.

## Results (MB/s, median of three)

| Profile | Write size | Baseline | Candidate |
| --- | ---: | ---: | ---: |
| streaming | 1 MiB | 32.6 | 60.1 |
| streaming | 8 MiB | 41.1 | 60.6 |
| streaming | 64 MiB | 63.4 | 60.5 |
| deduplication | 1 MiB | 22.4 | 44.7 |
| deduplication | 8 MiB | 24.7 | 33.9 |
| deduplication | 64 MiB | 36.3 | 35.7 |

The deduplication rows at 8 and 64 MiB were noisy in this run for both
variants (samples ranged 21–32 and 29–41 MB/s). An earlier full run of the
first candidate measured 24.8 → 44.7 MB/s at 8 MiB and 46.6 → 45.1 MB/s at
64 MiB.

Two SHA-256 passes over every byte (object id and chunk ids, about 179 MB/s
each on this CPU) cap ingest near 90 MB/s; this change does not alter them.
