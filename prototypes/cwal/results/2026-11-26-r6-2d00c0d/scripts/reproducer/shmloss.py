"""A writer dies in a cross window; an ordinary connection checkpoints main and dies; main's -shm is then deleted (lost). The next open must refuse with every WAL unchanged."""
import os, sys, subprocess
sys.path.insert(0, "/home/atawirtz/workspace/zova/prototypes/cwal")
import torture as t
work, n = sys.argv[1], int(sys.argv[2])
os.makedirs(work, exist_ok=True)
passed = 0
for i in range(n):
    d = t.dp_set(work, "shmloss")
    t.run(["nexec", d, "--files", 3], input=t.cross3(1))
    t.run(["nexec", d, "--files", 3], input=t.cross3(2), env={"CWAL_CRASH_TAG": "commit-sync-next", "CWAL_CRASH_AT": 1})
    t.plain_ckpt_die([os.path.join(d, "main.db")], "passive")
    os.remove(os.path.join(d, "main.db-shm"))
    before = t.wal_sizes(d)
    r = t.run(["nexec", d, "--files", 3, "--role", "reader", "--ready", 1], input="")
    after = t.wal_sizes(d)
    cerr, _ = t.ncheck(d, 3, "cwal", [])
    ok = "open-error ProtocolViolation" in r.stdout and before == after
    passed += ok
    print(f"trial={i} {'pass' if ok else 'FAIL'} | opener={' '.join(r.stdout.split())[:40]} wal={before}->{after} check={cerr or 'ok'}", flush=True)
print(f"SUMMARY shm-loss pass={passed}/{n}")
