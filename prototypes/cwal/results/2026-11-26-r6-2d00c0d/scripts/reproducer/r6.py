"""Run the R6 reproducer cases N times each against CWAL_BIN; one line per trial."""
import os, sys, shutil
sys.path.insert(0, "/home/atawirtz/workspace/zova/prototypes/cwal")
import torture
work, n = sys.argv[1], int(sys.argv[2])
os.makedirs(work, exist_ok=True)
for mode in sys.argv[3].split(","):
    passed = 0
    for i in range(n):
        ok, detail = torture.dp_r6(work, mode)
        passed += ok
        print(f"{mode} trial={i} {'pass' if ok else 'FAIL'} | {detail}", flush=True)
    print(f"SUMMARY {mode} pass={passed}/{n}", flush=True)
