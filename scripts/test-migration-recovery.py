"""Terminate real migration processes; never substitute returned-error cleanup."""
import hashlib
import os
import pathlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

driver = pathlib.Path(sys.argv[1]).resolve()
fixtures = pathlib.Path("tests/fixtures")
recover = pathlib.Path("scripts/recover-migration.py").resolve()

def digest(path):
    return hashlib.sha256(path.read_bytes()).digest()

def run_case(point):
    with tempfile.TemporaryDirectory(prefix="zova-migration-crash-") as tmp:
        root = pathlib.Path(tmp)
        names = ["bound-main-format-9.zova"] + [
            f"bound-main-format-9.{role}.zova" for role in ("objects", "vectors", "graphs")
        ]
        for name in names:
            shutil.copyfile(fixtures / name, root / name)
        source = root / names[0]
        with sqlite3.connect(source) as db:
            for role, suffix in (("object_store", "objects"), ("vector_store", "vectors"), ("graph_store", "graphs")):
                db.execute("update _zova_bound_stores set path=? where role=?", (str(root / f"bound-main-format-9.{suffix}.zova"), role))
        db.close()
        hashes = {name: digest(root / name) for name in names}
        dest = root / "result.zova"
        marker = root / "ready"
        child = subprocess.Popen([str(driver), str(source), str(dest), point, str(marker)])
        try:
            deadline = time.monotonic() + 30
            while not marker.exists():
                assert child.poll() is None, f"child exited before {point}"
                assert time.monotonic() < deadline, f"timeout at {point}"
                time.sleep(0.01)
        finally:
            child.kill()
            child.wait()
        assert all(digest(root / name) == value for name, value in hashes.items()), "source changed"
        assert pathlib.Path(str(dest) + ".migration-recovery").is_dir(), "missing ownership witnesses"
        recovery_dir = pathlib.Path(str(dest) + ".migration-recovery")
        if point == "before_main_publication":
            # Replacing even one destination must reject recovery of the whole
            # set, without deleting the user's file or any owned output.
            replaced = root / "result.objects.zova"
            witness = recovery_dir / replaced.name
            replaced.unlink()
            replaced.write_bytes(witness.read_bytes())  # Same bytes, different inode.
            state = {p: digest(p) for p in root.rglob("*") if p.is_file()}
            attempt = subprocess.run([sys.executable, str(recover), str(dest)], capture_output=True)
            assert attempt.returncode != 0
            assert all(p.exists() and digest(p) == value for p, value in state.items())
            replaced.unlink()  # Only the test owner restores its own fixture.
            os.link(witness, replaced)
            unexpected = recovery_dir / "unrelated.txt"
            unexpected.write_text("keep me")
            attempt = subprocess.run([sys.executable, str(recover), str(dest)], capture_output=True)
            assert attempt.returncode != 0 and unexpected.read_text() == "keep me"
            unexpected.unlink()
        subprocess.run([sys.executable, str(recover), str(dest)], check=True)
        if point != "after_main_publication":
            assert not dest.exists()
            assert not list(root.glob("result.*.zova"))
            subprocess.run([str(driver), str(source), str(dest), "none", str(marker)], check=True)
        assert dest.exists(), "retry did not publish"
        assert not recovery_dir.exists(), "successful migration left witnesses"
        assert all(digest(root / name) == value for name, value in hashes.items()), "retry changed source"
        print(f"migration termination/recovery: {point}: ok", flush=True)

for boundary in ("after_destination_reservation", "after_main_copy", "after_store_publication", "before_main_publication", "after_main_publication"):
    run_case(boundary)

# Stop recovery itself after each unlink. Retained commit proof must protect
# all published outputs; this checks filesystem behavior, not SQLite mocks.
for committed, stop_after in [(c, n) for c in (False, True) for n in range(1, 14)]:
    with tempfile.TemporaryDirectory(prefix="zova-recovery-cleanup-") as tmp:
        dest = pathlib.Path(tmp) / "result.zova"
        recovery_dir = pathlib.Path(str(dest) + ".migration-recovery")
        recovery_dir.mkdir()
        (recovery_dir / "owner").write_text("zova-migration-recovery-v1\n")
        finals = [dest] + [dest.with_name(f"result.{s}.zova") for s in ("objects", "vectors", "graphs")]
        for final in finals:
            reservation = recovery_dir / ("reserved-" + final.name)
            reservation.touch()
            stage = recovery_dir / final.name
            stage.write_bytes(b"published data")
            os.link(reservation if not committed and final == dest else stage, final)
        program = """
import os, pathlib, runpy, sys
count = 0
unlink = pathlib.Path.unlink
def interrupt(path, *args, **kwargs):
    global count
    unlink(path, *args, **kwargs)
    count += 1
    if count == int(sys.argv[3]):
        os._exit(87)
pathlib.Path.unlink = interrupt
runpy.run_path(sys.argv[1])["recover"](pathlib.Path(sys.argv[2]))
"""
        subprocess.run([sys.executable, "-c", program, str(recover), str(dest), str(stop_after)])
        if committed:
            assert all(p.read_bytes() == b"published data" for p in finals)
        # A missing owner is only possible after every witness is removed.
        if (recovery_dir / "owner").exists():
            subprocess.run([sys.executable, str(recover), str(dest)], check=True)
        if committed:
            assert all(p.read_bytes() == b"published data" for p in finals)
        else:
            assert not any(p.exists() for p in finals)
print("interrupted recovery preserves committed output and completes pending cleanup: ok", flush=True)
