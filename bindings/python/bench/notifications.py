import statistics
import time

import zova

EVENTS = 256
KV_BATCH = 4096
WARMUPS = 20
SAMPLES = 100


def now_ms():
    return time.perf_counter() * 1000.0


def report(label, values):
    med = statistics.median(values)
    deviations = [abs(v - med) for v in values]
    p95 = sorted(values)[int(len(values) * 0.95)]
    print(f"{label} median_ms={med:.6f} mad_ms={statistics.median(deviations):.6f} p95_ms={p95:.6f}")


def main():
    print(f"python events_per_iteration={EVENTS} kv_batch_entries={KV_BATCH}")
    db = zova.Database.create_memory()
    payloads = [f"event-{i}" for i in range(EVENTS)]

    def run(label, fn):
        samples = []
        for i in range(WARMUPS + SAMPLES):
            start = now_ms()
            fn()
            if i >= WARMUPS:
                samples.append(now_ms() - start)
        report(label, samples)

    run("commit_no_notify", lambda: (db.begin_immediate(), db.commit()))

    one_sub = db.listen("bench:one")
    run(
        "commit_one_notify",
        lambda: (
            db.begin_immediate(),
            db.notify("bench:one", payloads[0]),
            db.commit(),
            one_sub.try_receive(),
        ),
    )

    multi_subs = [db.listen("bench:multi") for _ in range(4)]

    def commit_multi():
        db.begin_immediate()
        for payload in payloads:
            db.notify("bench:multi", payload)
        db.commit()
        for sub in multi_subs:
            for _ in range(EVENTS):
                sub.try_receive()

    run("commit_256_four_listeners", commit_multi)

    entries = [(f"k-{i}".encode(), b"v") for i in range(KV_BATCH)]
    ns = b"bench:kv"

    def kv_batch_no_notify():
        db.begin_immediate()
        db.kv_put_many(ns, entries)
        db.commit()

    run("kv_batch_4096_commit_no_notify", kv_batch_no_notify)

    agg_sub = db.listen("cache:search-results")

    def kv_batch_notify():
        db.begin_immediate()
        db.kv_put_many(ns, entries)
        db.notify("cache:search-results", "generation:42")
        db.commit()
        agg_sub.try_receive()

    run("kv_batch_4096_commit_one_notify", kv_batch_notify)

    receive_sub = db.listen("bench:receive")
    samples = []
    for i in range(WARMUPS + SAMPLES):
        for payload in payloads:
            db.notify("bench:receive", payload)
        start = now_ms()
        for _ in range(EVENTS):
            receive_sub.try_receive()
        if i >= WARMUPS:
            samples.append(now_ms() - start)
    report("receive_256_prefilled", samples)


if __name__ == "__main__":
    main()