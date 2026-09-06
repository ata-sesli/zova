# Browser persistence evidence (#67)

The packed-artifact browser gate runs `durability-browser.mjs` through the
existing `check-browser-package.sh` harness. Local runs use installed Helium;
Linux CI uses Playwright Chromium. Native gates are unchanged.

## Covered boundaries

- Committed SQL and KV survive page reload without an explicit close or save.
- Explicit rollback leaves no partial SQL rows.
- The default connection uses DELETE journaling and FULL synchronization.
- Reload destroys a worker with an active transaction after approximately 1 MiB
  of writes with a small cache and an uncommitted index. Reopening verifies the
  original row count, committed KV, absent index and `PRAGMA integrity_check`.
- A test-only message after an actual OPFS write triggers `Worker.terminate()`
  while a transaction is active. Reopening verifies rollback and integrity.
  Browser teardown is asynchronous: post-termination opening retries only
  `ZOVA_BUSY` for at most five seconds. Other errors fail immediately.
- Injected `QuotaExceededError` and generic write/flush exceptions produce
  explicit errors. After removing the fault and reopening, committed data and
  integrity remain intact and no attempted insert is present.
- The surrounding gate covers unsupported storage, initialization failures,
  ownership cleanup, and incompatible files remaining byte-for-byte unchanged.

## Limits: not a general durability guarantee

Quota errors are injected at the synchronous OPFS boundary; this does not fill
the browser's real origin quota or test platform eviction policy. The browser
process stays running. Worker termination and page reload are not browser-process
termination, operating-system crash, or power loss. The write-triggered test does
not claim a precise interruption instruction inside SQLite or a commit-boundary
crash. Physical disk-full behavior, real quota exhaustion, browser-process kill,
and power-loss recovery remain unverified. No guarantees for those boundaries
should be inferred from this gate. Browser profiles and cleared site storage
remain outside application durability.

No large benchmark or performance claim is part of this test. The test fixture
uses 999 additional 1 KiB blobs and a small rollback journal/index.
