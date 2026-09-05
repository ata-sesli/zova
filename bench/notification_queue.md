# Issue #46: bounded notification ring

## Decision

Retain the ring buffer without copy-elision. FIFO, 1,024-entry drop-oldest policy, sequence/drop accounting, subscription lifetime and transaction publication remain unchanged. Dequeue and overflow eviction no longer shift the backlog. Growth alone copies live descriptors, amortized across enqueues; storage grows lazily from eight slots up to 1,024.

Fix a related receive-error ownership bug: the old code removed an item before cloning it and leaked its channel/payload if the caller allocator failed. The test reproduced a lost notification and two leaks. The new code clones first, preserving the queued item for retry on either allocation failure. Successful receives still copy into the requested allocator and release hub-owned bytes; allocator compatibility is not assumed.

## Method and limits

- Baseline source: `bca21cd` (issue #45) plus the same queue benchmark mode; candidate is this PR.
- Native macOS, Zig 0.16.0, SQLite 3.53.4, ReleaseFast. Package 1.0.0-rc.1 and format 11 unchanged.
- Extend the retained notification benchmark with the optional `queue` argument. Existing benchmark modes are unchanged.
- Depths 1, 16, 256, 1,024 and 2,048. The last overflows the unchanged 1,024 capacity. One listener, fixed nonempty channel/payload, 32 enqueue/drain bursts per depth per process. Validate sequence, payload, drop count and final emptiness on every burst.
- Build each binary once; one warmup followed by seven measured trials per variant, reversing baseline/candidate order each trial. Run one confirmation batch because the initial batch was visibly noisy. Both batches are retained below; no outliers discarded.
- Reported samples are **mean burst times across 32 rounds**, in microseconds, not individual-event latency. Nearest-rank p95 across seven samples is their maximum. Statistics do not establish a latency guarantee.
- A non-failing `FailingAllocator` wrapper counts successful allocation calls for the hub and received copies. It adds equal instrumentation overhead to both variants. No SQL/KV workload, durable writes or large payloads.
- External root `/Volumes/wipesides/codebase-memory-mcp-cache/zova-object-1m`, local cache `ROOT/local`, global cache `/Volumes/wipesides/codebase-memory-mcp-cache/zig-global`.
- Initial probe: `ROOT/issue46-trials.FJzmzK`. Initial comparison: `ROOT/issue46-trials.cvgMws`. Confirmation: `ROOT/issue46-trials.415YWP`.

## Results

Confirmation: full-queue drain median 450.379 → 129.954 µs (71.1% faster); overflow enqueue median 994.060 → 316.932 µs (68.1% faster). At depth one, combined median increased 0.301 → 0.315 µs (+4.7%, about 14 ns); do not claim a shallow-queue speedup. Larger combined burst medians and tails improved. Initial samples show scheduling noise, including some slower candidate phase maxima; the confirmation supports the backlog improvement, not every isolated phase maximum.

### Initial comparison

| Depth | Phase | Baseline median | Candidate median | Baseline p95 | Candidate p95 | Baseline MAD | Candidate MAD |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | enqueue | 0.171875 | 0.167906 | 0.522125 | 0.212313 | 0.002563 | 0.007781 |
| 1 | drain | 0.134094 | 0.136813 | 0.444031 | 0.175719 | 0.002469 | 0.001344 |
| 1 | combined | 0.307219 | 0.304656 | 0.966156 | 0.388032 | 0.005250 | 0.009093 |
| 16 | enqueue | 2.318938 | 2.319031 | 2.408938 | 2.989563 | 0.036344 | 0.020844 |
| 16 | drain | 2.324156 | 2.186219 | 2.738219 | 3.531313 | 0.048344 | 0.086063 |
| 16 | combined | 4.649657 | 4.524719 | 5.066344 | 5.802126 | 0.101407 | 0.152469 |
| 256 | enqueue | 35.149781 | 37.025969 | 61.225250 | 61.474000 | 0.912812 | 2.493406 |
| 256 | drain | 55.065031 | 38.761719 | 81.201813 | 89.433656 | 3.355375 | 4.321594 |
| 256 | combined | 90.386625 | 75.787688 | 142.427063 | 150.907656 | 3.861718 | 7.162563 |
| 1024 | enqueue | 209.002594 | 155.153656 | 417.416688 | 207.320281 | 74.899688 | 20.643093 |
| 1024 | drain | 586.067594 | 151.752563 | 1253.035219 | 213.593719 | 133.979125 | 21.718750 |
| 1024 | combined | 807.415282 | 306.906219 | 1670.451907 | 420.914000 | 220.981751 | 42.361843 |
| 2048 | enqueue | 1088.679656 | 342.143250 | 1393.358000 | 380.592344 | 95.621156 | 12.613125 |
| 2048 | drain | 509.180938 | 136.576844 | 665.324156 | 225.882875 | 51.595000 | 4.356656 |
| 2048 | combined | 1630.815062 | 478.720094 | 2058.682156 | 606.475219 | 182.160155 | 16.265406 |

Initial measured samples (1–7, warmup excluded):

| Depth | Variant | Enqueue µs | Drain µs |
|---:|---|---|---|
| 1 | baseline | 0.171875, 0.164031, 0.171875, 0.173125, 0.174438, 0.522125, 0.167969 | 0.138031, 0.132844, 0.134063, 0.134094, 0.138031, 0.444031, 0.131625 |
| 1 | candidate | 0.212313, 0.167906, 0.153625, 0.171906, 0.165313, 0.184906, 0.160125 | 0.175719, 0.136750, 0.138031, 0.135469, 0.136813, 0.144531, 0.135438 |
| 16 | baseline | 2.328125, 2.231719, 2.293000, 2.369719, 2.408938, 2.318938, 2.282594 | 2.738219, 2.237000, 2.281219, 2.324156, 2.372500, 2.330719, 2.265656 |
| 16 | candidate | 2.989563, 2.338500, 2.272094, 2.319031, 2.339875, 2.270813, 2.306031 | 2.755125, 2.186219, 2.100156, 2.180938, 2.773500, 3.531313, 2.157563 |
| 256 | baseline | 35.321594, 34.236969, 32.929656, 48.427188, 35.149781, 61.225250, 34.559813 | 55.065031, 52.287938, 51.709656, 68.977750, 58.761656, 81.201813, 54.546938 |
| 256 | candidate | 45.144438, 35.472750, 34.532563, 37.025969, 61.474000, 41.710875, 34.897094 | 42.834656, 33.152375, 32.677188, 38.761719, 89.433656, 41.102938, 34.440125 |
| 1024 | baseline | 134.102906, 133.085844, 209.002594, 314.001344, 221.347688, 417.416688, 140.906188 | 452.330625, 452.088469, 809.544281, 967.350313, 586.067594, 1253.035219, 476.602781 |
| 1024 | candidate | 160.363281, 133.834688, 134.510563, 155.153656, 141.753844, 180.997344, 207.320281 | 154.256406, 128.693938, 130.033813, 151.752563, 134.282469, 185.312469, 213.593719 |
| 2048 | baseline | 991.068969, 993.058500, 1243.921875, 1088.679656, 1180.783844, 1393.358000, 1032.585906 | 457.585938, 451.088563, 606.878938, 542.135406, 509.180938, 665.324156, 475.052031 |
| 2048 | candidate | 344.278719, 315.981844, 317.345094, 380.592344, 354.756375, 331.736844, 342.143250 | 140.933500, 128.634094, 128.403625, 225.882875, 140.229125, 134.360625, 136.576844 |

### Confirmation comparison

| Depth | Phase | Baseline median | Candidate median | Baseline p95 | Candidate p95 | Baseline MAD | Candidate MAD |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | enqueue | 0.170500 | 0.177094 | 0.183594 | 0.187438 | 0.003844 | 0.010344 |
| 1 | drain | 0.134125 | 0.139344 | 0.144531 | 0.149813 | 0.002562 | 0.002625 |
| 1 | combined | 0.300781 | 0.315063 | 0.328125 | 0.337251 | 0.003875 | 0.009063 |
| 16 | enqueue | 2.354125 | 2.285125 | 2.428344 | 2.418125 | 0.055906 | 0.092438 |
| 16 | drain | 2.338500 | 2.110719 | 3.037688 | 2.249969 | 0.076750 | 0.066406 |
| 16 | combined | 4.766844 | 4.395844 | 5.391813 | 4.668094 | 0.180969 | 0.183562 |
| 256 | enqueue | 34.347719 | 33.592406 | 36.113281 | 37.987000 | 0.572938 | 1.085812 |
| 256 | drain | 53.515563 | 33.639313 | 56.971344 | 34.669344 | 1.072844 | 1.028532 |
| 256 | combined | 87.934937 | 66.740938 | 92.403563 | 72.427156 | 1.264374 | 1.507813 |
| 1024 | enqueue | 133.604125 | 134.162781 | 140.433688 | 137.270781 | 1.820156 | 2.872375 |
| 1024 | drain | 450.378875 | 129.954313 | 474.776063 | 138.342531 | 5.226656 | 1.881313 |
| 1024 | combined | 583.654969 | 261.515688 | 615.209751 | 273.601687 | 6.621156 | 3.282406 |
| 2048 | enqueue | 994.059906 | 316.932344 | 1053.929719 | 335.250125 | 3.240875 | 1.605406 |
| 2048 | drain | 451.694000 | 129.774656 | 485.342438 | 136.626375 | 2.003781 | 1.007750 |
| 2048 | combined | 1446.197907 | 445.979031 | 1539.272157 | 471.535281 | 2.447782 | 2.914219 |

Confirmation measured samples (1–7, warmup excluded):

| Depth | Variant | Enqueue µs | Drain µs |
|---:|---|---|---|
| 1 | baseline | 0.170500, 0.166656, 0.171875, 0.166688, 0.162781, 0.182344, 0.183594 | 0.126344, 0.134125, 0.132781, 0.131563, 0.135406, 0.139344, 0.144531 |
| 1 | candidate | 0.160250, 0.177094, 0.166656, 0.187438, 0.157563, 0.177125, 0.178344 | 0.134094, 0.139344, 0.139344, 0.149813, 0.122313, 0.140531, 0.136719 |
| 16 | baseline | 2.240938, 2.298219, 2.398406, 2.304625, 2.354125, 2.428344, 2.411344 | 2.312469, 2.251344, 2.415250, 2.281250, 3.037688, 2.338500, 2.433563 |
| 16 | candidate | 2.265625, 2.308563, 2.285125, 2.154969, 2.135344, 2.418125, 2.377563 | 2.100188, 2.177125, 2.110719, 2.057313, 2.006406, 2.249969, 2.203156 |
| 256 | baseline | 34.227844, 34.347719, 33.774781, 34.588469, 32.826906, 35.432219, 36.113281 | 52.442719, 52.717438, 54.160156, 53.515563, 51.360813, 56.971344, 55.617063 |
| 256 | candidate | 34.929688, 32.506594, 33.013156, 32.958375, 33.592406, 37.987000, 36.820375 | 32.610781, 30.808625, 33.639313, 33.782563, 31.640719, 34.440156, 34.669344 |
| 1024 | baseline | 131.783969, 133.276094, 128.821719, 133.604125, 134.046906, 138.756500, 140.433688 | 458.492156, 450.378875, 445.152219, 448.838656, 448.490875, 467.932250, 474.776063 |
| 1024 | candidate | 128.203094, 130.964875, 134.162781, 134.334625, 131.290406, 137.270781, 135.259156 | 123.252563, 129.954313, 130.635313, 127.181063, 128.073000, 131.648438, 138.342531 |
| 2048 | baseline | 994.059906, 993.553438, 990.819031, 990.761688, 996.612125, 1053.929719, 1038.615813 | 449.690219, 451.575469, 451.694000, 455.436219, 450.278563, 485.342438, 480.232969 |
| 2048 | candidate | 318.238219, 313.898313, 315.326938, 316.204375, 316.932344, 328.136781, 335.250125 | 130.655031, 127.437500, 128.914094, 129.774656, 128.766906, 136.626375, 136.285156 |

## Allocations and memory

Counts and retained bytes were identical across measured trials within each depth/variant. Allocations are totals across all 32 bursts, including initial queue growth. Retained bytes are hub-tracked allocations after draining, including subscription storage and channel, not peak memory or SQLite memory.

| Depth | Baseline allocation calls | Candidate allocation calls | Baseline retained bytes | Candidate retained bytes |
|---:|---:|---:|---:|---:|
| 1 | 193 | 193 | 323 | 587 |
| 16 | 3073 | 3074 | 1427 | 971 |
| 256 | 49153 | 49158 | 17411 | 12491 |
| 1024 | 196609 | 196616 | 59075 | 49355 |
| 2048 | 327681 | 327688 | 59075 | 49355 |

Successful enqueues still allocate the original channel/payload and the delivered clone; successful receives still allocate two result buffers. No steady-state copy allocation reduction is claimed. Ring growth allocates/copies bounded storage instead of relying on ArrayList resizing, adding up to seven cold allocation calls in this fixture. At capacity, retained memory falls from 59,075 to 49,355 bytes; at depth one it increases by 264 bytes. This is a bounded memory tradeoff, not an across-the-board allocation optimization.

## Verification and reproduction

The failing-receive test was observed red with lost data and two leaks before production changes. Final Debug checks passed: 176/176 core tests, 226/226 C API tests, and C/C++ ABI smoke checks. ReleaseSafe core passed 176/176. Four new tests cover receive allocation failures at both copy allocations, wraparound/repeated overflow, wrapped growth failure/retry/unread teardown, and commit allocation failure/drop accounting. Existing core/API tests cover empty/full queues, subscription lifecycle and commit/rollback/savepoint publication. Formatting, shell syntax and whitespace checks passed. Full cross-platform/generated-C verification remains for CI.

Build each source once with `zig build build-notifications -Doptimize=ReleaseFast`, the same external cache flags, and `--prefix ROOT/issue46-baseline` or `ROOT/issue46-candidate`. Run `sh scripts/bench-notification-queue.sh ROOT` for a complete alternating batch; append `baseline` for a single initial probe. The script creates a fresh output directory. It runs only the new bounded `queue` mode, not the larger existing notification/KV benchmark.
