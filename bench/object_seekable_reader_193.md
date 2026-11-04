# Issue #193: seekable, verified object reader

## Result

`ObjectSeekableReader` serves sequential 32 KiB reads of a streaming-profile
object at 186 MB/s on an i7-6700HQ without SHA-NI. On the same object,
`readObjectRange` does 6.0 MB/s at that read size and `ObjectReader` does
99 MB/s. The new reader verifies each 1 MiB chunk once, against the 32 times
per chunk that `readObjectRange` needs, and it skips `ObjectReader`'s second,
whole-object hash. A random 64 KiB read still loads and hashes one full
chunk, about 5.5 ms, as the issue expected.

On the deduplication (FastCDC) profile, chunks average 8 KiB, so per-chunk
SQL work matters more than hashing. Sequential reads reach 93 MB/s, about the
same as `ObjectReader`. Random 64 KiB reads are about 9% slower than
`readObjectRange` because each chunk is a separate short read transaction.
A first version ran the FastCDC binary search for every chunk and managed
71 MB/s sequentially. The retained version loads the next index directly when
a read continues from the previous chunk.

## Method

- Machine: Intel i7-6700HQ (no SHA-NI), Fedora 45 (Linux 7.2.15), btrfs.
- Zig 0.17.0, `ReleaseFast`, bundled SQLite 3.53.4, default rollback journal,
  4 KiB pages, `foreign_keys = on`, production object schema through
  `object.Database.initForPrototype`.
- `zig build build-object-seekable-reader-193`. Each sample stores one
  256 MiB deterministic pseudo-random object (untimed), warms the cache with
  one full `ObjectReader` pass, then times every read pattern on that object
  in the same process. Every byte read is compared with the payload.
- Sequential `readObjectRange` covers only the first 32 MiB, because it is
  slow at 32 KiB per call. The random patterns use 256 offsets drawn from a
  fixed seed. p95 is the 244th of 256 sorted samples.
- Three samples per profile. The figures below are the median sample.
- The streaming samples were taken before the FastCDC next-index shortcut,
  which does not touch the streaming path. One streaming sample with the
  final code measured 188.1 MB/s sequential and 5.44 ms random p50.

## Results

| Read pattern | streaming | deduplication |
| --- | ---: | ---: |
| `readObjectRange`, sequential 32 KiB | 6.0 MB/s | 60.4 MB/s |
| `ObjectReader`, 32 KiB | 99.3 MB/s | 95.4 MB/s |
| `ObjectSeekableReader`, sequential 32 KiB | 185.8 MB/s | 93.4 MB/s |
| `readObjectRange`, random 64 KiB, p50 / p95 | 5.52 / 10.88 ms | 0.74 / 0.81 ms |
| `ObjectSeekableReader`, seek + random 64 KiB, p50 / p95 | 5.49 / 10.92 ms | 0.81 / 0.92 ms |
