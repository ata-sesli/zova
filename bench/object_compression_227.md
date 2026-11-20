# Issue #227: per-chunk LZ4 compression, ingest and read gate

## Decision

Retain opt-in LZ4 chunk compression. With compression off (the default), the
candidate matches the pre-#227 baseline on every measured path. With LZ4 on,
log-like text is stored 2.8× smaller with the streaming profile and 2.2×
smaller with the deduplication profile. The cost is lower throughput on
compressible data: 2–19% for ingest and 8–17% for sequential and
whole-object reads. A
random 64 KiB read of a 1 MiB streaming chunk takes about 2 ms longer, because
it decodes the whole chunk. On incompressible data, LZ4 stores every chunk raw
and costs nothing measurable.

The decoder is a plain bounds-checked LZ4 block decoder (one `@memcpy` per
literal run and match, no wild-copy fast path) and decodes at roughly
500 MB/s here. A faster decoder is a separate optimization; it was not
attempted in this change.

## Method

- Machine: Intel i7-6700HQ (no SHA-NI), 11 GiB RAM, Fedora 45 (Linux 7.2.15).
  The databases are on btrfs with `compress=zstd:1`. `file_bytes` below is
  SQLite's `page_count × page_size`, so filesystem compression does not
  affect it.
- Zig 0.17.0, `ReleaseFast`, bundled SQLite 3.53.4, default rollback journal,
  4 KiB pages, `foreign_keys = on`, production object schema through
  `object.Database.initForPrototype`.
- Harness: `bench/object_compression_227.zig`. Each sample stores one 256 MiB
  deterministic object through `ObjectWriter` with 8 MiB writes (timed through
  `finish`). Then, after one untimed warming pass, it times `getObject`,
  sequential 64 KiB reads through `ObjectReader` and `ObjectSeekableReader`,
  and 256 random 64 KiB reads through `readObjectRange` and a seek plus read on
  `ObjectSeekableReader`. Every read is compared with the payload; comparison
  time is excluded from the sequential reader rates.
- Fixtures: `text`, deterministic log lines (timestamp, level, service,
  request id, method, path, status, bytes, duration); `noise`, deterministic
  incompressible bytes.
- Variants: `baseline` is `e3f89a5` (the #226 branch, before #227) with the
  same harness copied in, compression off. `candidate-none` and
  `candidate-lz4` are the #227 tree with compression off and on.
- `scripts/bench-object-compression-227.sh`: per profile and fixture, one
  warmup and three measured samples with rotating variant order, a new
  database per sample. Medians of the three measured samples are reported.
- Raw output: external `issue227-trials.gKBZpu/` and `run.log`.

## Results (median of three)

Throughput in MB/s, latency is the p50 of 256 random reads in ms.

| Profile | Data | Variant | File MiB | LZ4 chunks | Ingest | `getObject` | `ObjectReader` | Seekable seq. | Range random | Seekable random |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| streaming | text | baseline | 256.4 | 0/256 | 68.9 | 171.2 | 100.3 | 191.2 | 5.452 | 5.420 |
| streaming | text | candidate-none | 256.4 | 0/256 | 68.8 | 171.0 | 100.3 | 190.0 | 5.502 | 5.441 |
| streaming | text | candidate-lz4 | 92.1 | 256/256 | 56.1 | 145.6 | 89.1 | 158.3 | 7.569 | 6.597 |
| streaming | noise | baseline | 256.4 | 0/256 | 62.8 | 170.4 | 100.2 | 190.6 | 5.487 | 5.421 |
| streaming | noise | candidate-none | 256.4 | 0/256 | 62.2 | 171.1 | 100.2 | 191.0 | 5.511 | 5.387 |
| streaming | noise | candidate-lz4 | 256.4 | 0/256 | 62.8 | 170.7 | 100.1 | 189.5 | 5.511 | 5.461 |
| deduplication | text | baseline | 278.0 | 0/28261 | 47.2 | 160.4 | 96.5 | 95.5 | 0.749 | 0.799 |
| deduplication | text | candidate-none | 278.0 | 0/28261 | 47.8 | 160.5 | 96.1 | 93.7 | 0.758 | 0.812 |
| deduplication | text | candidate-lz4 | 126.3 | 28261/28261 | 46.1 | 140.3 | 88.4 | 85.7 | 1.032 | 0.913 |
| deduplication | noise | baseline | 278.0 | 0/28631 | 46.9 | 159.8 | 96.3 | 95.2 | 0.753 | 0.819 |
| deduplication | noise | candidate-none | 278.0 | 0/28631 | 47.4 | 160.5 | 96.1 | 92.9 | 0.755 | 0.827 |
| deduplication | noise | candidate-lz4 | 278.0 | 0/28631 | 46.8 | 160.0 | 95.9 | 93.0 | 0.758 | 0.830 |

Format 14 adds one `encoding` byte per chunk row: the deduplication-profile
files grow by about 20 KiB (28k rows); the streaming files do not change size.
One `candidate-lz4` streaming/noise ingest sample was an outlier at 41.5 MB/s
(others 62.8 and 63.0). Data was read from a warm page cache, so these numbers
show the CPU cost of decoding, not any I/O saving from smaller files.

## Reproduction

Build each tree once with `zig build build-object-compression-227
-Doptimize=ReleaseFast --prefix ROOT/base` (baseline tree with the harness and
build step copied in) and `--prefix ROOT/cand`. Then run
`sh scripts/bench-object-compression-227.sh ROOT`. The script creates a new
results directory and removes each sample's database after the run.
