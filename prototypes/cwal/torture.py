#!/usr/bin/env python3
"""Crash, power-loss and concurrency torture for the CWAL prototype.

Every test runs both the CWAL protocol and the plain-WAL baseline. The
baseline uses the same VFS with the protocol off, so its failures show that
the oracle detects torn commits and mixed snapshots.

usage: torture.py [--work DIR] [--jobs N] [--only NAME ...]
"""
import argparse
import concurrent.futures as cf
import os
import random
import re
import shutil
import subprocess
import sys
import threading
import time
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "zig-out", "bin", "cwal")
ROUNDS = 20  # covers explicit, implicit, solo, spill, PASSIVE/RESTART/TRUNCATE


def run(args, env=None, timeout=60):
    e = dict(os.environ)
    for k in ("CWAL_CRASH_AT", "CWAL_POWERLOSS", "CWAL_SEED", "CWAL_TRACE"):
        e.pop(k, None)
    if env:
        e.update({k: str(v) for k, v in env.items()})
    return subprocess.run([BIN] + [str(a) for a in args], env=e, capture_output=True, text=True, timeout=timeout)


def acks(stdout):
    acked = {"pair": 0, "solo": 0, "solos": 0}
    for m in re.finditer(r"^ack (\w+) (\d+)$", stdout, re.M):
        acked[m.group(1)] = max(acked[m.group(1)], int(m.group(2)))
    return acked


def events(stdout):
    m = re.search(r"events=(\d+)", stdout)
    return int(m.group(1)) if m else None


def check(d, mode, acked, with_recovery=False):
    """Return None or the failure line (and, if asked, the recovery the
    check's open ran: none or rollback)."""
    r = run(["check", d, "--mode", mode, "--acked-pair", acked["pair"], "--acked-solo", acked["solo"], "--acked-solos", acked["solos"]])
    m = re.search(r"recovery=(\w+)", r.stdout)
    rec = m.group(1) if m else "-"
    if r.returncode == 0 and "check ok" in r.stdout:
        err = None
    else:
        line = (r.stdout + r.stderr).strip().splitlines()
        err = line[-1] if line else f"exit {r.returncode}"
    return (err, rec) if with_recovery else err


def reason(msg):
    return re.sub(r"[-\d]+", "#", msg)[:60]


def snap_state(d):
    """The seqlock page's fields, read without opening the set."""
    out = run(["state", d]).stdout
    return {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", out)}


class Progress:
    def __init__(self, label, total):
        self.label, self.total, self.done, self.t0, self.last = label, total, 0, time.time(), 0

    def tick(self):
        self.done += 1
        now = time.time()
        if now - self.last > 5 or self.done == self.total:
            self.last = now
            print(f"  [{self.label}] {self.done}/{self.total} ({now - self.t0:.0f}s)", flush=True)


def parallel(fn, items, jobs, label):
    prog = Progress(label, len(items))
    results = []
    with cf.ThreadPoolExecutor(jobs) as pool:
        for res in pool.map(fn, items):
            prog.tick()
            results.append(res)
    return results


# ---------------------------------------------------------------------------


def crash_matrix(work, tpl, mode, jobs, powerloss_seeds=(None,)):
    """Kill the writer at every fault event (and, with power loss, drop or
    tear unsynced writes), then recover and check."""
    d0 = os.path.join(work, f"full-{mode}")
    shutil.rmtree(d0, ignore_errors=True)
    shutil.copytree(tpl, d0)
    full = run(["writer", d0, "--mode", mode, "--rounds", ROUNDS])
    n = events(full.stdout)
    cases = [(k, seed) for seed in powerloss_seeds for k in range(1, n + 1)]

    def one(case):
        k, seed = case
        d = os.path.join(work, f"c-{mode}-{seed}-{k}")
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(tpl, d)
        env = {"CWAL_CRASH_AT": k}
        if seed is not None:
            env.update(CWAL_POWERLOSS=1, CWAL_SEED=seed)
        w = run(["writer", d, "--mode", mode, "--rounds", ROUNDS], env)
        acked = acks(w.stdout)
        # Only recovery tells whether the set was torn, so keep a copy until
        # it has run.
        snap = d + ".crashed"
        shutil.rmtree(snap, ignore_errors=True)
        shutil.copytree(d, snap)
        err, rec = check(d, mode, acked, with_recovery=True)
        shutil.rmtree(d, ignore_errors=True)
        if rec != "rollback":
            shutil.rmtree(snap, ignore_errors=True)
            snap = None
        return k, seed, rec, err, snap, acked

    results = parallel(one, cases, jobs, f"{mode} crash{' powerloss' if powerloss_seeds != (None,) else ''}")
    fails = [(k, s, e) for k, s, _, e, _, _ in results if e]
    recoveries = Counter(rec for _, _, rec, _, _, _ in results)
    snaps = [(snap, acked) for _, _, _, _, snap, acked in results if snap]
    return n, len(cases), fails, recoveries, snaps


def recovery_crash(work, snaps, jobs, powerloss_seeds=(None,), cap=40, files=None):
    """Crash recovery itself at every event, once and twice, then check.
    With files, the snapshots are N-file sets and acked is a list of
    (k, txn)."""
    extra = ["--files", files] if files else []
    verify = (lambda d, acked: ncheck(d, files, "cwal", acked)[0]) if files else (lambda d, acked: check(d, "cwal", acked))
    rng = random.Random(7)
    sample = snaps if len(snaps) <= cap else rng.sample(snaps, cap)
    cases = []
    for idx, (snap, acked) in enumerate(sample):
        d = snap + ".probe"
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(snap, d)
        m = events(run(["recover", d, "--mode", "cwal"] + extra).stdout) or 0
        shutil.rmtree(d, ignore_errors=True)
        for j in range(1, m + 1):
            for seed in powerloss_seeds:
                for twice in (False, True):
                    cases.append((idx, snap, acked, j, seed, twice))

    def one(case):
        idx, snap, acked, j, seed, twice = case
        d = f"{snap}.r{j}-{seed}-{int(twice)}"
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(snap, d)
        env = {"CWAL_CRASH_AT": j}
        if seed is not None:
            env.update(CWAL_POWERLOSS=1, CWAL_SEED=seed)
        run(["recover", d, "--mode", "cwal"] + extra, env)
        if twice:
            run(["recover", d, "--mode", "cwal"] + extra, env)
        err = verify(d, acked)
        shutil.rmtree(d, ignore_errors=True)
        return idx, j, seed, twice, err

    results = parallel(one, cases, jobs, "recovery crash")
    return len(sample), len(cases), [r for r in results if r[-1]]


# Readers tests widen the publication window so readers often start inside
# it (with snapshot reads, that exercises sqlite3_snapshot_open).
WINDOW_ENV = dict(os.environ, CWAL_WINDOW_DELAY_US="300")


def concurrent_readers(work, tpl, mode, ckpt):
    """Two reader processes (two threads each) against a live writer.
    ckpt=all includes RESTART/TRUNCATE checkpoints, which wait for readers;
    ckpt=passive keeps the writer committing while readers run."""
    d = os.path.join(work, f"rd-{mode}")
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(tpl, d)
    w = subprocess.Popen([BIN, "writer", d, "--mode", mode, "--rounds", "3000", "--delay-us", "200", "--ckpt", ckpt], env=WINDOW_ENV, stdout=subprocess.PIPE, text=True)
    time.sleep(0.1)
    rs = [subprocess.Popen([BIN, "reader", d, "--mode", mode, "--threads", "2", "--duration-ms", "2000", "--gap-us", "300", "--solo-order", "1"], stdout=subprocess.PIPE, text=True) for _ in range(2)]
    outs = [r.communicate()[0] for r in rs]
    wout = w.communicate()[0]
    stats = Counter()
    for o in outs:
        m = re.search(r"reader (.*)$", o, re.M)
        for kv in m.group(1).split():
            k, v = kv.split("=")
            stats[k] += int(v)
    err = check(d, mode, acks(wout))
    return stats, err


def surviving_readers(work, tpl, mode, trials, seed=11):
    """Kill the writer at a random event while reader processes keep
    running; restart a writer while they run; check afterwards."""
    rng = random.Random(seed)
    out = []
    prog = Progress(f"{mode} surviving readers", trials)
    for t in range(trials):
        d = os.path.join(work, f"sv-{mode}-{t}")
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(tpl, d)
        # Kill at a random fsync, or (CWAL) at a random phase-two
        # notification: after every member's commit frame is durable and
        # visible to readers, before the window closes.
        tag = "phase-two" if mode == "cwal" and t % 2 else "sync"
        k = rng.randint(5, 60)
        rs = [subprocess.Popen([BIN, "reader", d, "--mode", mode, "--threads", "2", "--duration-ms", "1500", "--gap-us", "100"], stdout=subprocess.PIPE, text=True) for _ in range(2)]
        time.sleep(0.05)
        e = dict(WINDOW_ENV, CWAL_CRASH_AT=str(k), CWAL_CRASH_TAG=tag)
        ckpt = "passive" if t % 4 >= 2 else "all"
        w = subprocess.run([BIN, "writer", d, "--mode", mode, "--rounds", "300", "--delay-us", "300", "--ckpt", ckpt], env=e, capture_output=True, text=True)
        acked = acks(w.stdout)
        crashed = w.returncode == -9
        # Restart a writer while the readers are still running.
        restart_broken = 0
        restarted = False
        deadline = time.time() + 1.0
        while time.time() < deadline:
            w2 = run(["writer", d, "--mode", mode, "--rounds", 12])
            if w2.returncode == 0:
                restarted = True
                a2 = acks(w2.stdout)
                for key in acked:
                    acked[key] = max(acked[key], a2[key])
                break
            if w2.returncode == 3:
                restart_broken += 1
                time.sleep(0.02)
                continue
            break
        stats = Counter()
        for r in rs:
            o = r.communicate()[0]
            m = re.search(r"reader (.*)$", o, re.M)
            for kv in m.group(1).split():
                kk, v = kv.split("=")
                stats[kk] += int(v)
        err = check(d, mode, acked)
        out.append(dict(k=f"{tag}#{k}", crashed=crashed, restarted=restarted, restart_broken=restart_broken, err=err, **stats))
        shutil.rmtree(d, ignore_errors=True)
        prog.tick()
    return out


def close_checkpoint(work, tpl, mode, n_syncs=40):
    """One reader connection stays open while the writer is killed at each of
    its first fsyncs; the reader then hits Broken (or not), closes as the
    last connection (SQLite checkpoints on close if it can), and we check."""
    fails = []
    prog = Progress(f"{mode} close checkpoint", n_syncs)
    for k in range(1, n_syncs + 1):
        d = os.path.join(work, f"cc-{mode}-{k}")
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(tpl, d)
        r = subprocess.Popen([BIN, "reader", d, "--mode", mode, "--threads", "1", "--duration-ms", "400"], stdout=subprocess.PIPE, text=True)
        time.sleep(0.05)
        e = dict(os.environ, CWAL_CRASH_AT=str(k), CWAL_CRASH_TAG="sync")
        w = subprocess.run([BIN, "writer", d, "--mode", mode, "--rounds", "300", "--delay-us", "300"], env=e, capture_output=True, text=True)
        r.communicate()
        err = check(d, mode, acks(w.stdout))
        if err:
            fails.append((k, err))
        shutil.rmtree(d, ignore_errors=True)
        prog.tick()
    return fails


def checkpoint_race(work, tpl, trials=3):
    """Snapshot opens skip SQLite's shared checkpoint lock and check the
    checkpoint counter instead. Widen the race: the writer pauses inside each
    checkpoint after choosing its end frame and before recording it, and the
    reader pauses inside the skipped lock. One reader thread, so no other
    read mark holds the checkpoint back. Each read then checks that no
    checkpoint recorded an intent to copy past its snapshot."""
    stats = Counter()
    errs = []
    for t in range(trials):
        d = os.path.join(work, f"cr-{t}")
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(tpl, d)
        we = dict(WINDOW_ENV, CWAL_CKPT_SCAN_DELAY_US="3000")
        w = subprocess.Popen([BIN, "writer", d, "--mode", "cwal", "--rounds", "3000", "--delay-us", "100", "--ckpt", "passive"], env=we, stdout=subprocess.PIPE, text=True)
        time.sleep(0.1)
        re_ = dict(os.environ, CWAL_CKPT_OPEN_DELAY_US="1000")
        r = subprocess.run([BIN, "reader", d, "--mode", "cwal", "--threads", "1", "--duration-ms", "2500", "--hold-us", "5000"], env=re_, capture_output=True, text=True)
        wout = w.communicate()[0]
        m = re.search(r"reader (.*)$", r.stdout, re.M)
        for kv in m.group(1).split():
            k, v = kv.split("=")
            stats[k] += int(v)
        err = check(d, "cwal", acks(wout))
        if err:
            errs.append(err)
    return stats, errs


def checkpoint_reset(work, tpl, trials=5):
    """A writer killed while it holds an exclusive checkpoint lock leaves
    the checkpoint counter's active count raised, so every later snapshot
    open would take the real lock. The next writer must clear it, also while
    a reader keeps the set open."""
    out = []
    for t in range(trials):
        d = os.path.join(work, f"ck-{t}")
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(tpl, d)
        w = run(["writer", d, "--mode", "cwal", "--rounds", ROUNDS], {"CWAL_CRASH_TAG": "ckpt-locked", "CWAL_CRASH_AT": t + 1})
        acked = acks(w.stdout)
        stuck = snap_state(d).get("ckpt_active", 0)
        r = subprocess.Popen([BIN, "reader", d, "--mode", "cwal", "--threads", "2", "--duration-ms", "1500"], stdout=subprocess.PIPE, text=True)
        time.sleep(0.1)
        w2 = subprocess.run([BIN, "writer", d, "--mode", "cwal", "--rounds", "300", "--delay-us", "300", "--ckpt", "passive"], env=WINDOW_ENV, capture_output=True, text=True)
        a2 = acks(w2.stdout)
        for key in acked:
            acked[key] = max(acked[key], a2[key])
        rout = r.communicate()[0]
        stats = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", rout)}
        after = snap_state(d).get("ckpt_active", -1)
        err = check(d, "cwal", acked)
        if w.returncode != -9 or w2.returncode != 0 or r.returncode != 0:
            err = err or f"exit codes writer={w.returncode} writer2={w2.returncode} reader={r.returncode}"
        out.append(dict(crash=t + 1, stuck=stuck, after=after, snapshot_reads=stats.get("snapshot_reads", 0), ckpt_fallbacks=stats.get("ckpt_fallbacks", 0), err=err))
        shutil.rmtree(d, ignore_errors=True)
    return out


# ---------------------------------------------------------------------------
# N-file sets (nseed/nwriter/nreader/ncheck)
# ---------------------------------------------------------------------------

NFILES = (2, 3, 4, 8, 16, 32)
# Every participating file's commit boundary: frame writes, WAL fsyncs,
# wal-index publication (barriers), and the protocol's own steps.
NTAGS = "write-wal,sync,shm-barrier,commit-hook,gate-acquire,phase-two"
NROUNDS = 20
# CWAL_DEBUG=1 makes every process log protocol decisions in the set.
DEBUG_ENV = {"CWAL_DEBUG": os.environ.get("CWAL_DEBUG", "0")}


def nacks(stdout, word="ack"):
    return [(int(k), int(t)) for k, t in re.findall(rf"^{word} (\d+) (\d+)$", stdout, re.M)]


def tagged(stdout):
    m = re.search(r"tagged=(\d+)", stdout)
    return int(m.group(1)) if m else None


def ncheck(d, n, mode, acked, with_recovery=True):
    """Return (failure line or None, recovery: none/rollback/-)."""
    path = d.rstrip("/") + ".acked"
    with open(path, "w") as f:
        f.writelines(f"{k} {t}\n" for k, t in acked)
    r = run(["ncheck", d, "--files", n, "--mode", mode, "--acked-file", path])
    os.unlink(path)
    m = re.search(r"recovery=(\w+)", r.stdout)
    rec = m.group(1) if m else "-"
    if r.returncode == 0 and "check ok" in r.stdout:
        return None, rec
    lines = (r.stdout + r.stderr).strip().splitlines()
    return (lines[-1] if lines else f"exit {r.returncode}"), rec


def drop_snaps(snaps):
    """Delete the torn states n_crash_matrix kept (32-file sets fill /tmp)."""
    for snap, _ in snaps:
        shutil.rmtree(snap, ignore_errors=True)


_template_lock = threading.Lock()


def ntemplate(work, n):
    """A seeded N-file set whose marker tables exist (a writer has opened
    it once), so crash points count only the workload."""
    tpl = os.path.join(work, f"ntpl-{n}")
    with _template_lock:
        if not os.path.isdir(tpl):
            os.makedirs(tpl)
            run(["nseed", tpl, "--files", n])
            run(["nwriter", tpl, "--files", n, "--rounds", 0])
    return tpl


def n_crash_matrix(work, n, mode, jobs, powerloss_seeds=(None,), cap=None):
    """Kill the writer at every commit-boundary event of every participating
    file (sampled down to cap), recover, and check atomicity, the prefix
    property, marker agreement and acknowledged commits."""
    tpl = ntemplate(work, n)
    d0 = os.path.join(work, f"nfull-{n}-{mode}")
    shutil.rmtree(d0, ignore_errors=True)
    shutil.copytree(tpl, d0)
    total = tagged(run(["nwriter", d0, "--files", n, "--mode", mode, "--rounds", NROUNDS], {"CWAL_CRASH_TAG": NTAGS}).stdout)
    shutil.rmtree(d0, ignore_errors=True)
    cases = [(t, seed) for seed in powerloss_seeds for t in range(1, total + 1)]
    if cap and len(cases) > cap:
        cases = sorted(random.Random(n).sample(cases, cap))

    def one(case):
        t, seed = case
        d = os.path.join(work, f"nc-{n}-{mode}-{seed}-{t}")
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(tpl, d)
        env = {"CWAL_CRASH_TAG": NTAGS, "CWAL_CRASH_AT": t}
        if seed is not None:
            env.update(CWAL_POWERLOSS=1, CWAL_SEED=seed)
        w = run(["nwriter", d, "--files", n, "--mode", mode, "--rounds", NROUNDS], env)
        acked = nacks(w.stdout)
        snap = d + ".crashed"
        shutil.rmtree(snap, ignore_errors=True)
        shutil.copytree(d, snap)
        err, rec = ncheck(d, n, mode, acked)
        shutil.rmtree(d, ignore_errors=True)
        with kept_lock:
            keep = rec == "rollback" and len(kept) < 40
            if keep:
                kept.append(t)
        if not keep:
            shutil.rmtree(snap, ignore_errors=True)
            snap = None
        return t, seed, rec, err, snap, acked, w.returncode

    # Keep at most 40 torn states for recovery_crash, which samples 8.
    kept, kept_lock = [], threading.Lock()

    label = f"{n} files {mode} crash{' powerloss' if powerloss_seeds != (None,) else ''}"
    results = parallel(one, cases, jobs, label)
    fails = [(t, s, e) for t, s, _, e, _, _, _ in results if e]
    recoveries = Counter(rec for _, _, rec, _, _, _, _ in results)
    crashed = sum(rc == -9 for *_, rc in results)
    snaps = [(snap, acked) for _, _, _, _, snap, acked, _ in results if snap]
    return total, len(cases), crashed, fails, recoveries, snaps


def reader_stats(text):
    stats = Counter()
    m = re.search(r"reader (.*)$", text, re.M)
    if m:
        for kv in m.group(1).split():
            k, v = kv.split("=")
            stats[k] += int(v)
    return stats


def n_restart_chain(work, n, seed, runs=15):
    """Reader processes keep the set open while a chain of writers is killed
    at random commit-boundary events and restarted, so most restarts run no
    recovery. Every fifth writer waits until the readers have ended and
    opens the set alone, so recovery runs over what earlier writers left.
    Checkpoints are PASSIVE only: RESTART and TRUNCATE would reset the WAL
    and hide frames a dead writer left behind. Afterwards: every attempted
    marker number was used once, every acknowledged k once, and every
    acknowledged commit survived."""
    rng = random.Random(seed)
    d = os.path.join(work, f"nr-{n}-{seed}")
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(ntemplate(work, n), d)
    reader_cmd = [BIN, "nreader", d, "--files", str(n), "--threads", "2", "--duration-ms", "1500", "--gap-us", "100"]
    readers = [subprocess.Popen(reader_cmd, stdout=subprocess.PIPE, text=True) for _ in range(2)]
    stats = Counter()
    tries, acked = [], []
    crashed = broken = 0
    reader_fails = []

    def reap(block=False):
        nonlocal readers
        alive = []
        for r in readers:
            if block or r.poll() is not None:
                text = r.communicate()[0]
                stats.update(reader_stats(text))
                stats["exit_nonzero"] += r.returncode != 0
                if r.returncode != 0:
                    reader_fails.append(text.strip().splitlines()[-1:] or [f"exit {r.returncode}"])
            else:
                alive.append(r)
        readers = alive

    for i in range(runs):
        reap(block=i % 5 == 4)
        if not readers and i % 5 != 4:
            readers = [subprocess.Popen(reader_cmd, stdout=subprocess.PIPE, text=True) for _ in range(2)]
        # A random working set, so later writers often leave untouched a
        # file an earlier one was killed while writing.
        use = rng.randint(2, n)
        env = {}
        if rng.random() < 0.8:
            env = {"CWAL_CRASH_TAG": NTAGS, "CWAL_CRASH_AT": rng.randint(1, 30 * n)}
        deadline = time.time() + 10
        while True:
            w = run(["nwriter", d, "--files", n, "--rounds", 30, "--seed", seed * 1000 + i, "--ckpt", "passive", "--use-files", use], env)
            tries += nacks(w.stdout, "try")
            acked += nacks(w.stdout)
            if w.returncode != 3 or time.time() > deadline:
                break
            broken += 1
            time.sleep(0.02)
        crashed += w.returncode == -9
        if w.returncode not in (0, -9):
            reap(block=True)
            return dict(n=n, seed=seed, err=f"writer exit {w.returncode}: {(w.stdout + w.stderr).strip()[-200:]}", **stats)
    reap(block=True)
    err, _ = ncheck(d, n, "cwal", acked)
    multi = [t for _, t in tries if t > 0]
    dup_txn = len(multi) - len(set(multi))
    ks = [k for k, _ in acked]
    dup_k = len(ks) - len(set(ks))
    if not err and dup_txn:
        err = f"{dup_txn} marker numbers attempted twice"
    if not err and dup_k:
        err = f"{dup_k} acknowledged k values reused"
    if not err and reader_fails:
        err = f"reader failed: {reader_fails[0]}"
    shutil.rmtree(d, ignore_errors=True)
    return dict(n=n, seed=seed, err=err, crashed=crashed, open_broken=broken, acked=len(acked), **stats)


def n_dangling(work, n, jobs, max_syncs=60):
    """The case the open-time discard exists for. A reader keeps the set
    open; the writer is killed at a WAL fsync, after a file's commit frames
    are written but before they are durable or published; the next writer
    leaves that file untouched (each file in turn); the reader ends and
    recovery runs alone. SQLite's WAL recovery would then accept the dead
    writer's frames unless the second writer dropped them."""
    tpl = ntemplate(work, n)
    d0 = os.path.join(work, f"ndfull-{n}")
    shutil.rmtree(d0, ignore_errors=True)
    shutil.copytree(tpl, d0)
    total = tagged(run(["nwriter", d0, "--files", n, "--rounds", NROUNDS], {"CWAL_CRASH_TAG": "sync"}).stdout)
    shutil.rmtree(d0, ignore_errors=True)
    cases = [(j, x) for j in range(1, min(total, max_syncs) + 1) for x in range(n)]
    every = (1 << n) - 1

    def one(case):
        j, x = case
        d = os.path.join(work, f"nd-{n}-{j}-{x}")
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(tpl, d)
        # The reader sleeps between finding W1 alive and mapping the
        # wal-indexes, so W1 often dies inside that gap (aloneAfterMapping).
        r = subprocess.Popen([BIN, "nreader", d, "--files", str(n), "--threads", "1", "--duration-ms", "700"], env=dict(os.environ, CWAL_ALIVE_DELAY_US="20000", **DEBUG_ENV), stdout=subprocess.PIPE, text=True)
        time.sleep(0.05)
        w1 = run(["nwriter", d, "--files", n, "--rounds", NROUNDS], {"CWAL_CRASH_TAG": "sync", "CWAL_CRASH_AT": j, **DEBUG_ENV})
        w2 = run(["nwriter", d, "--files", n, "--rounds", 6, "--file-mask", every & ~(1 << x), "--seed", j], DEBUG_ENV)
        rout = r.communicate()[0]
        alive = "reader" in rout and r.returncode == 0
        acked = nacks(w1.stdout) + nacks(w2.stdout)
        kept = d + ".before-check"
        shutil.rmtree(kept, ignore_errors=True)
        shutil.copytree(d, kept)
        err, rec = ncheck(d, n, "cwal", acked)
        if not err and w2.returncode not in (0, 3):
            err = f"second writer exit {w2.returncode}"
        if err:
            # Keep the set as the check found it, with both writers' output.
            err = f"{err} (writer exits {w1.returncode}/{w2.returncode}, kept {kept})"
            with open(kept + ".log", "w") as f:
                f.write(f"W1 {w1.returncode}\n{w1.stdout}{w1.stderr}\nW2 {w2.returncode}\n{w2.stdout}{w2.stderr}\nR {r.returncode}\n{rout}")
        else:
            shutil.rmtree(kept, ignore_errors=True)
        shutil.rmtree(d, ignore_errors=True)
        return j, x, err, w1.returncode == -9, alive, reader_stats(rout)

    results = parallel(one, cases, jobs, f"{n} files dangling frames")
    stats = Counter()
    for *_, st in results:
        stats.update(st)
    fails = [(j, x, e) for j, x, e, *_ in results if e]
    crashed = sum(c for _, _, _, c, _, _ in results)
    reader_ok = sum(a for _, _, _, _, a, _ in results)
    return total, len(cases), crashed, reader_ok, fails, stats


def n_readers(work, n, mode, ckpt):
    """A live writer with a widened window and 2 reader processes x 2
    threads; every read must see whole transactions and a prefix."""
    d = os.path.join(work, f"nrd-{n}-{mode}-{ckpt}")
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(ntemplate(work, n), d)
    w = subprocess.Popen([BIN, "nwriter", d, "--files", str(n), "--mode", mode, "--rounds", "100000", "--delay-us", "200", "--ckpt", ckpt], env=WINDOW_ENV, stdout=subprocess.PIPE, text=True)
    time.sleep(0.1)
    rs = [subprocess.Popen([BIN, "nreader", d, "--files", str(n), "--mode", mode, "--threads", "2", "--duration-ms", "2000", "--gap-us", "300"], stdout=subprocess.PIPE, text=True) for _ in range(2)]
    stats = Counter()
    for r in rs:
        stats.update(reader_stats(r.communicate()[0]))
    w.terminate()
    wout = w.communicate()[0]
    # The writer was stopped (SIGTERM) mid-run: like a crash.
    err, _ = ncheck(d, n, mode, nacks(wout))
    shutil.rmtree(d, ignore_errors=True)
    return stats, err


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", default=os.environ.get("CWAL_WORK", "/tmp/cwal-torture"))
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--powerloss-seeds", type=int, default=3)
    ap.add_argument("--survivor-trials", type=int, default=20)
    ap.add_argument("--files", type=int, nargs="*", default=list(NFILES))
    ap.add_argument("--ncap", type=int, default=3000, help="max crash points per file count")
    ap.add_argument("--restart-seeds", type=int, default=4)
    a = ap.parse_args()
    shutil.rmtree(a.work, ignore_errors=True)
    os.makedirs(a.work)
    tpl = os.path.join(a.work, "tpl")
    os.makedirs(tpl)
    run(["seed", tpl])
    want = lambda name: not a.only or name in a.only
    failed = False
    pl = tuple(range(1, a.powerloss_seeds + 1))

    if want("crash"):
        print("== process crash at every writer event", flush=True)
        snaps = {}
        for mode in ("plain", "cwal"):
            n, total, fails, recoveries, s = crash_matrix(a.work, tpl, mode, a.jobs)
            snaps[mode] = s
            print(f"{mode}: events={n} runs={total} failures={len(fails)} recoveries={dict(recoveries)}")
            for r, cnt in Counter(reason(e) for _, _, e in fails).most_common(5):
                print(f"    {cnt:5d}  {r}")
            failed |= mode == "cwal" and bool(fails)
        if want("recovery"):
            print("== crash during recovery (every recovery event, once and twice)", flush=True)
            n, total, fails = recovery_crash(a.work, snaps["cwal"], a.jobs)
            print(f"cwal: torn states={n} runs={total} failures={len(fails)}")
            for f in fails[:5]:
                print("    ", f)
            failed |= bool(fails)

    if want("powerloss"):
        print(f"== power loss at every writer event, {len(pl)} seeds (unsynced writes dropped or torn)", flush=True)
        snaps = []
        for mode in ("plain", "cwal"):
            n, total, fails, recoveries, s = crash_matrix(a.work, tpl, mode, a.jobs, pl)
            if mode == "cwal":
                snaps = s
            print(f"{mode}: events={n} runs={total} failures={len(fails)} recoveries={dict(recoveries)}")
            for r, cnt in Counter(reason(e) for _, _, e in fails).most_common(5):
                print(f"    {cnt:5d}  {r}")
            failed |= mode == "cwal" and bool(fails)
        print("== power loss during recovery", flush=True)
        n, total, fails = recovery_crash(a.work, snaps, a.jobs, pl, cap=20)
        print(f"cwal: torn states={n} runs={total} failures={len(fails)}")
        for f in fails[:5]:
            print("    ", f)
        failed |= bool(fails)

    if want("readers"):
        print("== concurrent snapshots: writer + 2 reader processes x 2 threads", flush=True)
        for ckpt in ("all", "passive"):
            for mode in ("plain", "cwal"):
                stats, err = concurrent_readers(a.work, tpl, mode, ckpt)
                print(f"{mode} ckpt={ckpt}: {dict(stats)} check={'ok' if not err else err}")
                failed |= mode == "cwal" and (stats["mixed"] != 0 or stats["ckpt_violations"] != 0 or bool(err))

    if want("survivors"):
        print("== writer killed while reader processes keep running", flush=True)
        for mode in ("plain", "cwal"):
            res = surviving_readers(a.work, tpl, mode, a.survivor_trials)
            agg = Counter()
            for r in res:
                for k in ("reads", "mixed", "broken", "ckpt_denied", "restart_broken", "snapshot_reads", "seq_retries", "snapshot_waits", "ckpt_races", "ckpt_violations"):
                    agg[k] += r[k]
            errs = [r for r in res if r["err"]]
            print(f"{mode}: trials={len(res)} crashed={sum(r['crashed'] for r in res)} restarted={sum(r['restarted'] for r in res)} {dict(agg)} check_failures={len(errs)}")
            for r in errs[:3]:
                print("    ", r["k"], r["err"])
            failed |= mode == "cwal" and (agg["mixed"] != 0 or agg["ckpt_violations"] != 0 or bool(errs))

    if want("ckptrace"):
        print("== checkpoint starts during a snapshot open (widened race)", flush=True)
        stats, errs = checkpoint_race(a.work, tpl)
        print(f"cwal: {dict(stats)} check_failures={len(errs)}")
        failed |= stats["ckpt_violations"] != 0 or stats["mixed"] != 0 or bool(errs) or (stats["ckpt_races"] == 0 and os.environ.get("CWAL_MUTATE") != "no-ckpt-skip")

    if want("ckptreset"):
        print("== writer killed holding a checkpoint lock; the next writer clears the counter", flush=True)
        res = checkpoint_reset(a.work, tpl)
        for r in res:
            print(f"    crash at ckpt-locked#{r['crash']}: active after crash={r['stuck']} after next writer={r['after']} snapshot_reads={r['snapshot_reads']} ckpt_fallbacks={r['ckpt_fallbacks']} check={'ok' if not r['err'] else r['err']}")
        failed |= any(r["stuck"] == 0 or r["after"] != 0 or r["err"] for r in res)

    if want("closeckpt"):
        print("== last reader closes after the writer is killed at each of its first 40 fsyncs", flush=True)
        for mode in ("plain", "cwal"):
            fails = close_checkpoint(a.work, tpl, mode)
            print(f"{mode}: runs=40 check_failures={len(fails)}")
            for k, e in fails[:3]:
                print(f"     sync#{k} {e[:120]}")
            failed |= mode == "cwal" and bool(fails)

    if want("nfiles"):
        print(f"== N files: process crash at every commit-boundary event ({NTAGS})", flush=True)
        for n in a.files:
            for mode in ("plain", "cwal"):
                total, runs, crashed, fails, recoveries, snaps = n_crash_matrix(a.work, n, mode, a.jobs, cap=a.ncap)
                print(f"{n} files {mode}: events={total} runs={runs} crashed={crashed} failures={len(fails)} recoveries={dict(recoveries)}")
                for r, cnt in Counter(reason(e) for _, _, e in fails).most_common(3):
                    print(f"    {cnt:5d}  {r}")
                failed |= mode == "cwal" and (bool(fails) or crashed != runs)
                if mode == "cwal" and n in (3, 8, 32) and snaps:
                    nt, total_r, rfails = recovery_crash(a.work, snaps, a.jobs, cap=8, files=n)
                    print(f"{n} files cwal recovery crash: torn states={nt} runs={total_r} failures={len(rfails)}")
                    for f in rfails[:3]:
                        print("    ", f)
                    failed |= bool(rfails)
                drop_snaps(snaps)
        print("== N files: power loss at every commit-boundary event (sampled)", flush=True)
        for n in [x for x in a.files if x in (3, 8, 32)]:
            for mode in ("plain", "cwal"):
                total, runs, crashed, fails, recoveries, snaps = n_crash_matrix(a.work, n, mode, a.jobs, pl, cap=a.ncap)
                drop_snaps(snaps)
                print(f"{n} files {mode} powerloss: events={total} runs={runs} failures={len(fails)} recoveries={dict(recoveries)}")
                for r, cnt in Counter(reason(e) for _, _, e in fails).most_common(3):
                    print(f"    {cnt:5d}  {r}")
                failed |= mode == "cwal" and bool(fails)

    if want("nrestart"):
        print("== N files: writer chain killed and restarted while readers keep the set open", flush=True)
        cases = [(n, s) for n in a.files for s in range(1, a.restart_seeds + 1)]
        res = parallel(lambda c: n_restart_chain(a.work, *c), cases, max(1, a.jobs // 4), "restart chains")
        for n in a.files:
            rs = [r for r in res if r["n"] == n]
            agg = Counter()
            for r in rs:
                for k in ("crashed", "open_broken", "acked", "reads", "mixed", "broken", "snapshot_reads", "ckpt_violations", "exit_nonzero"):
                    agg[k] += r.get(k, 0)
            errs = [r for r in rs if r["err"]]
            print(f"{n} files: chains={len(rs)} {dict(agg)} failures={len(errs)}")
            for r in errs[:3]:
                print(f"     seed {r['seed']}: {r['err'][:160]}")
            failed |= bool(errs) or agg["mixed"] != 0 or agg["ckpt_violations"] != 0

    if want("ndangle"):
        print("== N files: frames a killed writer left unpublished, next writer skips that file", flush=True)
        for n in a.files:
            total, runs, crashed, reader_ok, fails, stats = n_dangling(a.work, n, a.jobs)
            print(f"{n} files: syncs={total} runs={runs} crashed={crashed} reader_ok={reader_ok} mixed={stats['mixed']} failures={len(fails)}")
            for r, cnt in Counter(reason(e) for _, _, e in fails).most_common(3):
                print(f"    {cnt:5d}  {r}")
            for j, x, e in fails[:3]:
                print(f"     sync#{j} skip file {x}: {e}")
            failed |= bool(fails) or stats["mixed"] != 0

    if want("nreaders"):
        print("== N files: live writer + 2 reader processes x 2 threads", flush=True)
        for n in a.files:
            for mode in ("plain", "cwal") if n in (3, 8) else ("cwal",):
                for ckpt in ("all", "passive"):
                    stats, err = n_readers(a.work, n, mode, ckpt)
                    keys = ("reads", "mixed", "broken", "snapshot_reads", "seq_retries", "snapshot_waits", "ckpt_violations")
                    print(f"{n} files {mode} ckpt={ckpt}: {dict((k, stats[k]) for k in keys)} check={'ok' if not err else err}")
                    failed |= mode == "cwal" and (stats["mixed"] != 0 or stats["ckpt_violations"] != 0 or bool(err))

    print("RESULT", "FAIL" if failed else "PASS")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
