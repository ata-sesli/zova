#!/bin/bash
# flock / mmap / fsync observations on the external APFS disk, and the sync
# calls the bundled SQLite issues. Builds and scratch files stay on that disk.
set -e
Z=/Users/atasesli/Desktop/VsCode/zova
R=$Z/prototypes/cwal/results/2026-11-27-macos-arm64-0f418a0
D=/Volumes/wipesides/codebase-memory-mcp-cache/cwal-t1-apfs
S=$Z/vendor/sqlite3.53.4
rm -rf $D; mkdir -p $D
mount | grep ' /Volumes/wipesides ' || true
cc -O1 -Wall -o $D/apfs_checks $R/scripts/apfs_checks.c
$D/apfs_checks $D
echo "== bundled SQLite sync calls"
# Same SQLite options as prototypes/cwal/build.zig, plus the fsync counter.
cc -O1 -c -o $D/sqlite3.o -DSQLITE_THREADSAFE=1 -DSQLITE_ENABLE_SNAPSHOT -DSQLITE_MAX_ATTACHED=31 -Dfsync=counted_fsync $S/sqlite3.c
cc -O1 -I$S -o $D/sqlite_sync_check $R/scripts/sqlite_sync_check.c $D/sqlite3.o
$D/sqlite_sync_check $D
echo "== sqlite3MemoryBarrier in the prototype binary"
otool -tV $Z/prototypes/cwal/zig-out/bin/cwal | awk '/^_sqlite3MemoryBarrier:/{p=1} p{print} p&&/ret/{exit}'
rm -rf $D
echo APFS-CHECKS-DONE
