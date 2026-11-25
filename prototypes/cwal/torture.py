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
    check's open ran: none, forward or rollback)."""
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


def state(d):
    return run(["state", d]).stdout.split()[-1]


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
        st = state(d) if mode == "cwal" else "-"
        # With commit markers the journal stays idle; only recovery tells
        # whether the set was torn, so keep a copy until it has run.
        snap = d + ".crashed"
        shutil.rmtree(snap, ignore_errors=True)
        shutil.copytree(d, snap)
        err, rec = check(d, mode, acked, with_recovery=True)
        shutil.rmtree(d, ignore_errors=True)
        needed = st in ("prepared", "broken") or rec == "rollback"
        if not needed:
            shutil.rmtree(snap, ignore_errors=True)
            snap = None
        return k, seed, f"{st}/{rec}" if needed else st, err, snap, acked

    results = parallel(one, cases, jobs, f"{mode} crash{' powerloss' if powerloss_seeds != (None,) else ''}")
    fails = [(k, s, e) for k, s, _, e, _, _ in results if e]
    states = Counter(st for _, _, st, _, _, _ in results)
    snaps = [(snap, acked) for _, _, _, _, snap, acked in results if snap]
    return n, len(cases), fails, states, snaps


def recovery_crash(work, snaps, jobs, powerloss_seeds=(None,), cap=40):
    """Crash recovery itself at every event, once and twice, then check."""
    rng = random.Random(7)
    sample = snaps if len(snaps) <= cap else rng.sample(snaps, cap)
    cases = []
    for idx, (snap, acked) in enumerate(sample):
        d = snap + ".probe"
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(snap, d)
        m = events(run(["recover", d, "--mode", "cwal"]).stdout) or 0
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
        run(["recover", d, "--mode", "cwal"], env)
        if twice:
            run(["recover", d, "--mode", "cwal"], env)
        err = check(d, "cwal", acked)
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
        # visible to readers, before the journal says committed.
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", default=os.environ.get("CWAL_WORK", "/tmp/cwal-torture"))
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--powerloss-seeds", type=int, default=3)
    ap.add_argument("--survivor-trials", type=int, default=20)
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
            n, total, fails, states, s = crash_matrix(a.work, tpl, mode, a.jobs)
            snaps[mode] = s
            print(f"{mode}: events={n} runs={total} failures={len(fails)} journal_states={dict(states)}")
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
            n, total, fails, states, s = crash_matrix(a.work, tpl, mode, a.jobs, pl)
            if mode == "cwal":
                snaps = s
            print(f"{mode}: events={n} runs={total} failures={len(fails)} journal_states={dict(states)}")
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
                failed |= mode == "cwal" and (stats["mixed"] != 0 or bool(err))

    if want("survivors"):
        print("== writer killed while reader processes keep running", flush=True)
        for mode in ("plain", "cwal"):
            res = surviving_readers(a.work, tpl, mode, a.survivor_trials)
            agg = Counter()
            for r in res:
                for k in ("reads", "mixed", "broken", "ckpt_denied", "restart_broken", "snapshot_reads", "seq_retries", "snapshot_waits"):
                    agg[k] += r[k]
            errs = [r for r in res if r["err"]]
            print(f"{mode}: trials={len(res)} crashed={sum(r['crashed'] for r in res)} restarted={sum(r['restarted'] for r in res)} {dict(agg)} check_failures={len(errs)}")
            for r in errs[:3]:
                print("    ", r["k"], r["err"])
            failed |= mode == "cwal" and (agg["mixed"] != 0 or bool(errs))

    if want("closeckpt"):
        print("== last reader closes after the writer is killed at each of its first 40 fsyncs", flush=True)
        for mode in ("plain", "cwal"):
            fails = close_checkpoint(a.work, tpl, mode)
            print(f"{mode}: runs=40 check_failures={len(fails)}")
            for k, e in fails[:3]:
                print(f"     sync#{k} {e[:120]}")
            failed |= mode == "cwal" and bool(fails)

    print("RESULT", "FAIL" if failed else "PASS")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
