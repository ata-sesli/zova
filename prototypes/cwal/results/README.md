# Raw test results

Each subdirectory holds the unedited output of one verification run, so the
numbers quoted in `README.md`, `REVIEW.md` and `notes/cwal-integration-260.md`
can be checked and reproduced.

Layout of `<date>-<purpose>-<commit>/`:

| Path | Contents |
|---|---|
| `MANIFEST.md` | Source commit, what ran, the exact commands, and which log backs which claim. |
| `HOST.txt` | Kernel, CPU, memory, Zig and Python versions, scratch filesystem. |
| `binaries/SHA256SUMS` | Hashes of the `cwal` binaries that ran. The binaries themselves are not kept. Rebuild them from the commit with `zig build -Doptimize=<mode>`. Hashes identify a build on that host; they are not reproducible-build claims. |
| `scripts/` | The driver scripts as run. Paths in them point at the session's scratch directory. Substitute your own. |
| `logs/` | Raw stdout and stderr of every run. |

Logs are not edited after the run. A later correction goes in a new run
directory, or in a note added to `MANIFEST.md`.
