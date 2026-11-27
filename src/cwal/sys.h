/* POSIX interfaces used by src/cwal/cwal.zig (translated as `cwal_sys`).
 * SQLite itself comes from the shared `sqlite_c` module. */
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <signal.h>
#include <time.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
#include <sys/mman.h>
