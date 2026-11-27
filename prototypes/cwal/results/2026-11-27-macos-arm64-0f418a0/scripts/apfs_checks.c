/* flock, mmap and fsync behavior on the filesystem holding argv[1].
 * Observations only; nothing here is a pass/fail gate for the prototype. */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static char path[1024];

static int xopen(void) {
  int fd = open(path, O_RDWR | O_CREAT, 0644);
  if (fd < 0) { perror("open"); exit(2); }
  return fd;
}

/* Run `op` in a child on a fresh open(); return 0 or the errno. */
static int child_try(int op) {
  pid_t p = fork();
  if (p == 0) {
    int fd = xopen();
    _exit(flock(fd, op) == 0 ? 0 : (errno == EWOULDBLOCK ? 100 : 101));
  }
  int st; waitpid(p, &st, 0);
  return WEXITSTATUS(st);
}
static const char *r(int v) { return v == 0 ? "granted" : v == 100 ? "EWOULDBLOCK" : "other-error"; }

static double now(void) {
  struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void flock_checks(void) {
  int fd = xopen();
  printf("== flock\n");
  flock(fd, LOCK_EX);
  printf("holder EX: other process SH|NB=%s EX|NB=%s\n", r(child_try(LOCK_SH | LOCK_NB)), r(child_try(LOCK_EX | LOCK_NB)));
  int fd2 = xopen();
  int same = flock(fd2, LOCK_SH | LOCK_NB);
  printf("holder EX: second open() in the same process SH|NB=%s\n", same == 0 ? "granted" : (errno == EWOULDBLOCK ? "EWOULDBLOCK" : "other-error"));
  close(fd2);
  flock(fd, LOCK_SH);
  printf("holder SH: other process SH|NB=%s EX|NB=%s\n", r(child_try(LOCK_SH | LOCK_NB)), r(child_try(LOCK_EX | LOCK_NB)));
  flock(fd, LOCK_UN);

  /* fork-inherited descriptor shares the lock: child unlock releases it. */
  flock(fd, LOCK_EX);
  pid_t p = fork();
  if (p == 0) { flock(fd, LOCK_UN); _exit(0); }
  waitpid(p, NULL, 0);
  printf("EX held, forked child unlocks the inherited fd: other process EX|NB=%s\n", r(child_try(LOCK_EX | LOCK_NB)));
  flock(fd, LOCK_UN);

  /* Failed SH->EX conversion: does the caller keep its shared lock? */
  int pipe_a[2], pipe_b[2];
  pipe(pipe_a); pipe(pipe_b);
  flock(fd, LOCK_SH);
  p = fork();
  if (p == 0) { /* second shared holder */
    int f = xopen(); flock(f, LOCK_SH);
    write(pipe_a[1], "x", 1);
    char ch; read(pipe_b[0], &ch, 1);
    flock(f, LOCK_UN); write(pipe_a[1], "y", 1);
    read(pipe_b[0], &ch, 1); _exit(0);
  }
  char ch; read(pipe_a[0], &ch, 1);
  int up = flock(fd, LOCK_EX | LOCK_NB);
  int up_errno = errno;
  write(pipe_b[1], "g", 1); read(pipe_a[0], &ch, 1); /* other holder released */
  int third = child_try(LOCK_EX | LOCK_NB);
  printf("two SH holders, one tries SH->EX|NB: %s; afterwards a third process EX|NB=%s => failed conversion %s the shared lock\n",
         up == 0 ? "granted" : (up_errno == EWOULDBLOCK ? "EWOULDBLOCK" : "other-error"), r(third),
         third == 0 ? "DROPPED" : "KEPT");
  write(pipe_b[1], "g", 1); waitpid(p, NULL, 0);
  flock(fd, LOCK_UN);

  /* EX->SH conversion with a blocked EX waiter: can the waiter get in first? */
  int trials = 200, intervened = 0;
  for (int i = 0; i < trials; i++) {
    int mark[2]; pipe(mark);
    fcntl(mark[0], F_SETFL, O_NONBLOCK);
    flock(fd, LOCK_EX);
    p = fork();
    if (p == 0) {
      int f = xopen();
      flock(f, LOCK_EX); /* blocks */
      write(mark[1], "m", 1);
      flock(f, LOCK_UN); _exit(0);
    }
    usleep(2000); /* let the child block */
    flock(fd, LOCK_SH); /* convert */
    if (read(mark[0], &ch, 1) == 1) intervened++;
    flock(fd, LOCK_UN);
    waitpid(p, NULL, 0);
    close(mark[0]); close(mark[1]);
  }
  printf("EX->SH conversion with a blocked EX waiter: waiter took EX before the conversion returned in %d of %d trials\n", intervened, trials);

  /* SH->EX conversion with a blocked EX waiter (the path the prototype relies
   * on the gate for): the waiter wins if the conversion unlocks first. */
  intervened = 0;
  for (int i = 0; i < trials; i++) {
    int mark[2]; pipe(mark);
    fcntl(mark[0], F_SETFL, O_NONBLOCK);
    flock(fd, LOCK_SH);
    p = fork();
    if (p == 0) {
      int f = xopen();
      flock(f, LOCK_EX);
      write(mark[1], "m", 1);
      flock(f, LOCK_UN); _exit(0);
    }
    usleep(2000);
    flock(fd, LOCK_EX);
    if (read(mark[0], &ch, 1) == 1) intervened++;
    flock(fd, LOCK_UN);
    waitpid(p, NULL, 0);
    close(mark[0]); close(mark[1]);
  }
  printf("SH->EX conversion with a blocked EX waiter: waiter took EX before the conversion returned in %d of %d trials\n", intervened, trials);

  /* Lock of a killed holder is released. */
  int ready[2]; pipe(ready);
  p = fork();
  if (p == 0) { int f = xopen(); flock(f, LOCK_EX); write(ready[1], "r", 1); pause(); _exit(0); }
  read(ready[0], &ch, 1);
  int before = child_try(LOCK_EX | LOCK_NB);
  kill(p, SIGKILL); waitpid(p, NULL, 0);
  printf("holder EX then SIGKILL: before=%s after=%s\n", r(before), r(child_try(LOCK_EX | LOCK_NB)));
  close(fd);
}

static void mmap_checks(void) {
  printf("== mmap\n");
  printf("getpagesize=%d\n", getpagesize());
  int fd = xopen();
  ftruncate(fd, 0); ftruncate(fd, 4096);
  uint8_t *m = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (m == MAP_FAILED) { perror("mmap"); return; }
  printf("mmap(4096, MAP_SHARED) of a 4096-byte file: ok\n");

  /* A store in another process's separate mapping is visible here. */
  int go[2], done[2]; pipe(go); pipe(done);
  pid_t p = fork();
  if (p == 0) {
    int f = xopen();
    uint8_t *cm = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, f, 0);
    char ch; read(go[0], &ch, 1);
    cm[7] = 0xAB;
    write(done[1], "d", 1);
    read(go[0], &ch, 1);
    uint8_t buf = 0; pread(f, &buf, 1, 9);
    _exit(cm[8] == 0xCD && buf == 0xEF ? 0 : 1);
  }
  char ch; write(go[1], "g", 1); read(done[0], &ch, 1);
  uint8_t via_pread = 0; pread(fd, &via_pread, 1, 7);
  printf("store through another process's mapping: seen in this mapping=%s, seen by pread=%s (no msync)\n",
         m[7] == 0xAB ? "yes" : "NO", via_pread == 0xAB ? "yes" : "NO");
  m[8] = 0xCD;
  uint8_t ef = 0xEF; pwrite(fd, &ef, 1, 9);
  write(go[1], "g", 1);
  int st; waitpid(p, &st, 0);
  printf("this process's mapped store and pwrite: seen by the other process=%s; pwrite seen in this mapping=%s\n",
         WEXITSTATUS(st) == 0 ? "yes" : "NO", m[9] == 0xEF ? "yes" : "NO");

  /* Atomic increments from four processes through separate mappings. */
  uint64_t *ctr = (uint64_t *)(m + 64);
  *ctr = 0;
  const int procs = 4, per = 1000000;
  pid_t kids[4];
  for (int i = 0; i < procs; i++) {
    kids[i] = fork();
    if (kids[i] == 0) {
      int f = xopen();
      uint8_t *cm = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, f, 0);
      uint64_t *c = (uint64_t *)(cm + 64);
      for (int k = 0; k < per; k++) __atomic_fetch_add(c, 1, __ATOMIC_SEQ_CST);
      _exit(0);
    }
  }
  for (int i = 0; i < procs; i++) waitpid(kids[i], NULL, 0);
  printf("atomic counter, %d processes x %d increments through separate mappings: %llu (expected %d)\n",
         procs, per, (unsigned long long)*ctr, procs * per);
  munmap(m, 4096);
  close(fd);
}

static void sync_checks(void) {
  printf("== fsync timing (4096-byte overwrite then sync, same file)\n");
  int fd = xopen();
  ftruncate(fd, 0);
  char buf[4096]; memset(buf, 0x5a, sizeof buf);
  struct { const char *name; int cmd; } modes[] = {
    {"fsync", -1}, {"fcntl(F_BARRIERFSYNC)", F_BARRIERFSYNC}, {"fcntl(F_FULLFSYNC)", F_FULLFSYNC}};
  const int n = 200;
  for (int m = 0; m < 3; m++) {
    int failed = 0;
    double t = now();
    for (int i = 0; i < n; i++) {
      buf[0] = (char)i;
      pwrite(fd, buf, sizeof buf, 0);
      int rc = modes[m].cmd < 0 ? fsync(fd) : fcntl(fd, modes[m].cmd, 0);
      if (rc != 0) failed++;
    }
    double dt = now() - t;
    printf("%-22s %d calls %.3f s  %.2f ms/call  failures=%d\n", modes[m].name, n, dt, dt * 1000 / n, failed);
  }
  close(fd);
}

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: apfs_checks DIR\n"); return 2; }
  setvbuf(stdout, NULL, _IOLBF, 0);
  snprintf(path, sizeof path, "%s/apfs-check.bin", argv[1]);
  flock_checks();
  mmap_checks();
  sync_checks();
  unlink(path);
  return 0;
}
