/* Which sync call the bundled SQLite issues on macOS, by counting.
 * sqlite3.c is compiled with -Dfsync=counted_fsync; F_FULLFSYNC goes through
 * the unix VFS's overridable fcntl system call. */
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "sqlite3.h"

static int n_fsync, n_full, n_barrier;

#undef fsync
int counted_fsync(int fd) { n_fsync++; return fsync(fd); }

static int my_fcntl(int fd, int cmd, ...) {
  va_list ap; va_start(ap, cmd);
  void *arg = va_arg(ap, void *);
  va_end(ap);
  if (cmd == F_FULLFSYNC) n_full++;
  if (cmd == F_BARRIERFSYNC) n_barrier++;
  return fcntl(fd, cmd, arg);
}

static sqlite3 *db;
static void sql(const char *s) {
  char *err = 0;
  if (sqlite3_exec(db, s, 0, 0, &err) != SQLITE_OK) { printf("SQL error: %s: %s\n", s, err); sqlite3_free(err); }
}
static int pragma_int(const char *s) {
  sqlite3_stmt *st; int v = -1;
  if (sqlite3_prepare_v2(db, s, -1, &st, 0) == SQLITE_OK && sqlite3_step(st) == SQLITE_ROW) v = sqlite3_column_int(st, 0);
  sqlite3_finalize(st);
  return v;
}
static void phase(const char *name, const char *s) {
  n_fsync = n_full = n_barrier = 0;
  sql(s);
  printf("%-44s fsync=%d F_FULLFSYNC=%d F_BARRIERFSYNC=%d\n", name, n_fsync, n_full, n_barrier);
}

int main(int argc, char **argv) {
  if (argc != 2) return 2;
  char path[1024], shm[1100];
  snprintf(path, sizeof path, "%s/sync-check.db", argv[1]);
  snprintf(shm, sizeof shm, "%s-shm", path);
  sqlite3_vfs *vfs = sqlite3_vfs_find("unix");
  vfs->xSetSystemCall(vfs, "fcntl", (sqlite3_syscall_ptr)my_fcntl);
  printf("sqlite %s, vfs %s\n", sqlite3_libversion(), sqlite3_vfs_find(0)->zName);
  if (sqlite3_open(path, &db) != SQLITE_OK) return 1;
  sql("PRAGMA journal_mode=WAL");
  printf("defaults: fullfsync=%d checkpoint_fullfsync=%d synchronous=%d\n",
         pragma_int("PRAGMA fullfsync"), pragma_int("PRAGMA checkpoint_fullfsync"), pragma_int("PRAGMA synchronous"));
  sql("CREATE TABLE t(a)");
  struct stat st;
  if (stat(shm, &st) == 0) printf("-shm size=%lld bytes, getpagesize=%d\n", (long long)st.st_size, getpagesize());

  sql("PRAGMA synchronous=FULL");
  phase("default, synchronous=FULL, 1 commit", "INSERT INTO t VALUES(1)");
  phase("default, synchronous=FULL, checkpoint", "PRAGMA wal_checkpoint(TRUNCATE)");
  sql("PRAGMA synchronous=NORMAL");
  phase("default, synchronous=NORMAL, 1 commit", "INSERT INTO t VALUES(2)");
  phase("default, synchronous=NORMAL, checkpoint", "PRAGMA wal_checkpoint(TRUNCATE)");

  sql("PRAGMA synchronous=FULL; PRAGMA fullfsync=1");
  phase("fullfsync=1, synchronous=FULL, 1 commit", "INSERT INTO t VALUES(3)");
  phase("fullfsync=1, synchronous=FULL, checkpoint", "PRAGMA wal_checkpoint(TRUNCATE)");
  sql("PRAGMA fullfsync=0; PRAGMA checkpoint_fullfsync=1");
  phase("ckpt_fullfsync=1, sync=FULL, 1 commit", "INSERT INTO t VALUES(4)");
  phase("ckpt_fullfsync=1, sync=FULL, checkpoint", "PRAGMA wal_checkpoint(TRUNCATE)");
  sqlite3_close(db);
  unlink(path);
  return 0;
}
