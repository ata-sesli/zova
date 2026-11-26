import os, sys, subprocess, time
sys.path.insert(0, "/home/atawirtz/workspace/zova/prototypes/cwal")
import torture as t
work = sys.argv[1]
d = t.dp_set(work, "dbg")
t.run(["nexec", d, "--files", 3], input=t.cross3(1))
w1 = t.run(["nexec", d, "--files", 3], input=t.cross3(2), env={"CWAL_CRASH_TAG": "commit-sync-next", "CWAL_CRASH_AT": 1})
o, pf, reached = t.paused(["nexec", d, "--files", 3, "--role", "reader", "--ready", 1], d, point="recover-truncate", extra_env={"CWAL_DEBUG": 1})
print("reached", reached, "pid", o.pid)
ino = os.stat(os.path.join(d, "main.db")).st_ino
print("main.db inode", ino)
print("ALL", [l.strip() for l in open("/proc/locks") if f" {o.pid} " in l])
for l in open("/proc/locks"):
    if f":{ino} " in l: print("LOCK", l.strip())
print("fds:", [os.readlink(f"/proc/{o.pid}/fd/{f}") for f in os.listdir(f"/proc/{o.pid}/fd")])
t.go(pf); print(o.communicate(input="")[0][:200]); print(t.debug_log(d)[-800:])
