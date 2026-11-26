#!/usr/bin/env python3
"""Section 7: realistic workloads, plain WAL vs rollback journal vs CWAL.

For each scenario: seeds a WAL set and a rollback-journal set once, then
(1) calibrates each mode's maximum writer rate (closed loop, readers at a
fixed rate), and (2) runs every mode at the same fixed writer rate, a
fraction of the slowest mode's maximum. Each run starts from a fresh copy
of the seeded set.

  ./workload.py --dir /dev/shm/cwal-wl                 # all scenarios, 10 s runs
  ./workload.py --dir ~/cwal-wl --scenarios mixed --duration 60
  ./workload.py --dir ~/cwal-wl --scenarios mixed --readers 2,8,16 --read-rate 50 \
      --duration 600 --report 30 --check     # 10-minute runs, integrity checked
"""
import argparse, os, re, shutil, subprocess, sys, time

BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "zig-out/bin/cwal")
MODES = ["plain", "journal", "cwal"]
SCENARIOS = ["mixed", "objects", "vectors", "graph"]
# Seed and per-scenario options. Readers run at a fixed rate everywhere.
SEED = ["--docs", "2000", "--object-kib", "16", "--big", "4", "--big-mib", "16"]
READERS = {"mixed": (2, 200), "objects": (2, 10), "vectors": (2, 20), "graph": (2, 200)}


def kv(line):
    return dict(re.findall(r"(\w+)=(\S+)", line))


def wrun(set_dir, mode, scenario, rate, duration, report=0, extra=(), readers=None, read_rate=None):
    readers = readers or READERS[scenario][0]
    read_rate = read_rate or READERS[scenario][1]
    args = [BIN, "wrun", set_dir, "--mode", mode, "--scenario", scenario, "--rate", rate,
            "--readers", readers, "--read-rate", read_rate, "--duration-s", duration, "--report-s", report, *extra]
    p = subprocess.Popen([str(a) for a in args], stdout=subprocess.PIPE, text=True)
    res = {"ops": [], "intervals": []}
    for line in p.stdout:
        if line.startswith("interval"):
            print("   ", line.strip(), flush=True)
            res["intervals"].append({k: float(v) for k, v in kv(line).items()})
        elif line.startswith(("summary", "resources", "health")):
            print("   ", line.strip(), flush=True)
            res.update(kv(line))
        elif line.startswith("op "):
            res["ops"].append(kv(line))
        elif line.startswith("FAIL"):
            print("   ", line.strip(), flush=True)
    if p.wait() != 0:
        sys.exit(f"wrun {mode} {scenario} failed ({p.returncode})")
    return res


def fresh(base, mode, scenario):
    src = os.path.join(base, "seed-" + ("delete" if mode == "journal" else "wal"))
    dst = os.path.join(base, f"run-{scenario}-{mode}")
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(src, dst)
    return dst


def row(r):
    f = lambda k: r.get(k, "-")
    return (f"{r['mode']:8} {float(f('write_ops_s')):9.1f} {f('write_p50_us'):>8} {f('write_p95_us'):>8} {f('write_p99_us'):>8} "
            f"{f('write_max_us'):>8} {float(f('read_ops_s')):8.1f} {f('read_p50_us'):>8} {f('read_p99_us'):>8} {f('read_retries'):>6} "
            f"{f('cpu_s'):>6} {f('peak_rss_mb'):>6} {f('write_amp'):>6} {f('disk_write_amp'):>6} {f('fsyncs_per_write_op'):>6} {f('peak_wal_mb'):>7}")


def trend(r):
    """First third vs last third of the interval reports."""
    iv = r["intervals"]
    if len(iv) < 3:
        return ""
    k = len(iv) // 3
    a, b = iv[:k], iv[-k:]
    m = lambda xs, f: sum(x[f] for x in xs) / len(xs)
    return (f"{r['mode']:8} readers={r.get('readers')} rss_mb {m(a, 'rss_mb'):.1f}->{m(b, 'rss_mb'):.1f} "
            f"write_ops_s {m(a, 'write_ops_s'):.2f}->{m(b, 'write_ops_s'):.2f} "
            f"write_p99_ms {m(a, 'write_p99_us') / 1e3:.0f}->{m(b, 'write_p99_us') / 1e3:.0f} "
            f"read_ops_s {m(a, 'read_ops_s'):.0f}->{m(b, 'read_ops_s'):.0f} "
            f"read_p99_ms {m(a, 'read_p99_us') / 1e3:.1f}->{m(b, 'read_p99_us') / 1e3:.1f} "
            f"min_reader_ops_s {min(x['min_reader_ops_s'] for x in iv):.1f} "
            f"wal_mb max {max(x['wal_mb'] for x in iv):.1f} "
            f"ckpt_complete {r.get('ckpt_complete')}/{r.get('ckpt_runs')} "
            f"reader_ops {r.get('reader_ops_min')}..{r.get('reader_ops_max')} of {r.get('reader_ops_offered')} "
            f"writer_ops {r.get('writer_ops')} of {r.get('writer_ops_offered')}")


HEAD = (f"{'mode':8} {'write/s':>9} {'w_p50us':>8} {'w_p95us':>8} {'w_p99us':>8} {'w_maxus':>8} {'read/s':>8} "
        f"{'r_p50us':>8} {'r_p99us':>8} {'r_retr':>6} {'cpu_s':>6} {'rss_mb':>6} {'wamp':>6} {'dwamp':>6} {'fs/op':>6} {'wal_mb':>7}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--scenarios", default=",".join(SCENARIOS))
    ap.add_argument("--modes", default=",".join(MODES))
    ap.add_argument("--duration", type=float, default=10)
    ap.add_argument("--calibrate", type=float, default=3, help="seconds per calibration run")
    ap.add_argument("--fraction", type=float, default=0.5, help="of the slowest mode's max rate")
    ap.add_argument("--rate", type=float, help="fixed writer rate; skips calibration")
    ap.add_argument("--report", type=float, default=0, help="interval report period (s)")
    ap.add_argument("--keep", action="store_true", help="keep the run sets")
    ap.add_argument("--readers", default="", help="comma list of reader counts (default per scenario)")
    ap.add_argument("--read-rate", type=float, help="reads/s per reader (default per scenario)")
    ap.add_argument("--ckpt-every", type=int, default=100, help="writer ops between PASSIVE checkpoints")
    ap.add_argument("--check", action="store_true", help="run wcheck on every set after its run")
    a = ap.parse_args()
    base = os.path.abspath(os.path.expanduser(a.dir))
    modes = a.modes.split(",")
    os.makedirs(base, exist_ok=True)
    for journal in ("wal", "delete"):
        d = os.path.join(base, "seed-" + journal)
        if not os.path.exists(os.path.join(d, "main.db")):
            shutil.rmtree(d, ignore_errors=True)
            os.makedirs(d)
            print(subprocess.run([BIN, "wseed", d, "--journal", journal, *SEED], capture_output=True, text=True, check=True).stdout.strip(), flush=True)

    reader_counts = [int(x) for x in a.readers.split(",")] if a.readers else [None]
    extra = ["--ckpt-every", a.ckpt_every]
    for sc in a.scenarios.split(","):
        rate = a.rate
        if rate is None:
            maxes = {}
            # Calibrate at the heaviest reader load.
            nmax = max(reader_counts, key=lambda n: n or 0)
            for m in modes:
                d = fresh(base, m, sc)
                r = wrun(d, m, sc, 0, a.calibrate, extra=extra, readers=nmax, read_rate=a.read_rate)
                maxes[m] = float(r["write_ops_s"])
                shutil.rmtree(d)
                print(f"calibrate {sc} {m}: max {maxes[m]:.1f} write ops/s (readers {nmax or READERS[sc][0]}x{a.read_rate or READERS[sc][1]:g}/s)", flush=True)
            rate = round(a.fraction * min(maxes.values()), 2)
        for n in reader_counts:
            readers = n or READERS[sc][0]
            read_rate = a.read_rate or READERS[sc][1]
            print(f"\n== {sc}: writer {rate} ops/s, readers {readers} x {read_rate:g}/s, {a.duration:g} s", flush=True)
            results = []
            for m in modes:
                d = fresh(base, m, sc)
                t = time.time()
                r = wrun(d, m, sc, rate, a.duration, a.report, extra=extra, readers=readers, read_rate=read_rate)
                if a.check:
                    ck = subprocess.run([BIN, "wcheck", d, "--mode", m], capture_output=True, text=True)
                    r["check"] = (ck.stdout.strip().splitlines() or ["?"])[-1]
                    print(f"    {r['check']}", flush=True)
                    if ck.returncode != 0:
                        print(ck.stdout, flush=True)
                print(f"   {m} done in {time.time() - t:.0f} s", flush=True)
                results.append(r)
                if not a.keep:
                    shutil.rmtree(d)
            print(HEAD)
            for r in results:
                print(row(r))
            print("per op (p50/p99 us):")
            for r in results:
                print(f"  {r['mode']:8} " + "  ".join(f"{o['side'][0]}:{o['kind']} {o['p50_us']}/{o['p99_us']}" for o in r["ops"]))
            if any(r["intervals"] for r in results):
                print("trend (first third -> last third):")
                for r in results:
                    print("  " + trend(r))
            if a.check:
                print("integrity: " + "; ".join(f"{r['mode']} {r['check']}" for r in results))
            sys.stdout.flush()


main()
