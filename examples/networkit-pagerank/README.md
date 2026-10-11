# NetworKit PageRank reference plugin

On-demand PageRank over a Zova graph, implemented by NetworKit's C++ algorithm
through the versioned C plugin ABI. This is a development reference for 1.2.0,
not a bundled extension or a published NetworKit package.

## Build and try

Requires a C++20 compiler, CMake 3.20+, Ninja and OpenMP. The test runner also
needs Zova's pinned Zig toolchain and Python. macOS uses Homebrew `libomp`;
Linux normally uses GCC's OpenMP runtime; Windows requires the MSVC developer
environment and its OpenMP runtime. Binaries must match the host OS/CPU/runtime.

```sh
python3 scripts/check-networkit-pagerank.py /path/to/new/external-output --bench
```

The directory must not exist. Builds use two jobs. The optional measurement is
only 2,048 nodes and 8,192 edges: one warmup, three recorded calls, one compute
thread. This command builds, packages and tests the reference, including a bound
graph store. Windows additionally requires `--packages` as described below.
The Windows C++ test host links the checked generated-C objects with compiler
builtins from the same installed Zig toolchain; MSVC's linker does not supply
these helpers. This runtime is linked into the test executable, not the plugin.

The resulting bundle is `external-output/installed/networkit.zovaext`. It must
be explicitly trusted and selected with Zova's normal create/open extension
options; opening never grants trust. The runner uses an isolated trust store.
Do not copy its trust file into another application's configuration.

After installing the `networkit` extension on your graph database, use ordinary
statements in C, Zig, Rust, Python, Go or JavaScript:

```sql
SELECT node_key, node_id, score, iterations, converged
FROM zova_networkit_pagerank('links', 0.85, 1e-10, 200, 10000, 100000)
ORDER BY score DESC, node_id;
```

All six arguments are required: graph name, damping, L1 tolerance, maximum
iterations, maximum input nodes, maximum input edges. Damping/tolerance are
SQL FLOAT values, not integer literals. Damping is in `[0,1)`, tolerance in
`(0,1]`, and iterations in `1..1000`. Node/edge limits can be zero but cannot
exceed 250,000 / 1,000,000. Exceeding input limits fails before result delivery.
Potential work `(nodes + edges) * max_iterations` is capped at 100 million.
These bound retained input and iterative work, not a strict process-RSS sandbox.

## Result semantics

- Opaque node keys and public IDs come from Zova; no private schema is queried.
- Every node participates, including isolated nodes. Empty graphs return zero rows.
- Directed edges have equal weight. Different types between the same endpoints
  contribute multiplicity, combined into a weighted NetworKit edge. Self-loops
  are retained. There is no edge-type filter in this reference.
- Dangling-node probability is redistributed uniformly. Scores are finite,
  nonnegative and sum to one. NetworKit's separate `normalized` option is off.
- This is finite numerical power iteration, declared `APPROXIMATE`. `iterations`
  reports actual work; `converged` checks the final vector's L1 fixed-point residual.
  Reaching the iteration cap does not imply convergence. Inspect that field.
- Emission follows Zova's node creation order. Use SQL `ORDER BY` for ranked output.
- Each SQL cursor computes once from its pinned snapshot, including bound stores
  and earlier caller writes. No persistent index or cross-call cache exists.
- `load_ms`, `convert_ms`, `compute_ms`, `result_ms` report scan/copy, dense mapping
  plus topology conversion, NetworKit computation, and score/result construction.
  SQL preparation, delivery/copying and final cleanup are included in the runner's
  complete `total_ms`, not all in those four internal counters.

The whole graph is materialized before the first row; SQL `LIMIT 1` does not
make the algorithm a partial-graph calculation. Reset, error and finalization
release cursor memory. Computations are serialized within this plugin module,
use one OpenMP worker, and restore the caller's thread budget. The private
NetworKit instance does not replace the process SIGINT handler. Cancellation
is observed in host scans/delivery, not asynchronously inside the bounded
NetworKit iteration. Native code remains trusted process code.

## Reproducible author build

The CMake file pins NetworKit **11.2.2**, commit
`6b3878ee00a6eadd50be3b3047fbcae56bcac685`, and its exact TLX submodule
`2dd63ab839909f0b43cd02108a1869c4670b2c8e`. Both archive SHA-256 checksums are
required. Only nine NetworKit implementation files are compiled; the full toolkit,
Python bindings and upstream tests are not built. No dependency enters Zova core.

```sh
cmake -S examples/networkit-pagerank -B /external/build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release
cmake --build /external/build --parallel 2
cmake --install /external/build --prefix /external/release
```

For direct macOS CMake builds, supply the local OpenMP include/library hints;
the check runner provides them automatically. All platforms require their
shared toolchain OpenMP runtime. Do not privately duplicate `libomp` into each
plugin: applications already using OpenMP can abort when a second copy loads.
Choose one compatible shared runtime for the whole application; if distributing
it, set application-level runtime paths and preserve its license. The reference
runner uses the installed toolchain runtime, rather than promising a self-contained
universal bundle. Treat runtime selection as part of author packaging.
NetworKit's MIT license and TLX's Boost license are installed in the bundle;
the OpenMP runtime is not copied or redistributed by this runner.

## Verification

The C++ executable uses only the public Zova C ABI and the real dynamically
loaded plugin. It covers analytic scores, dangling/isolated nodes, self-loops,
typed multiplicity, key/ID mapping, deterministic order, limits, errors, caller
rollback, old WAL readers, bound stores, early close and read-only reopen.

To check the actual language packages, first run the retained native-package
runner, then provide its output:

```sh
python3 scripts/check-plugin-packages.py /external/native-packages
python3 scripts/check-networkit-pagerank.py /external/pagerank \
  --packages /external/native-packages --bench
```

This additionally executes a safe Rust nextest fixture, Go/cgo, an installed
Python wheel and an installed npm tarball under Node and Bun. CI uses that path.
WASM native-plugin loading remains outside this reference's scope.
