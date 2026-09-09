"""Reject failed or incomplete benchmark runs instead of reporting a gate."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class GraphIndexRunnerTests(unittest.TestCase):
    def test_failed_benchmark_process_fails_runner(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            commands = root / "commands"
            commands.mkdir()
            timeout = commands / "timeout"
            timeout.write_text("#!/bin/sh\nexit 42\n")
            timeout.chmod(0o755)
            result = subprocess.run(
                ["sh", str(ROOT / "scripts/bench-graph-index-ddl-95.sh"), str(root)],
                env={**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"]},
                capture_output=True, text=True, timeout=15,
            )
            self.assertNotEqual(result.returncode, 0)

    def test_empty_matrix_cannot_report_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "trials.log"
            log.write_text("")
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/analyze-graph-index-ddl-95.py"), str(log)],
                capture_output=True, text=True, timeout=15,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("PASS", result.stdout)

    def test_complete_matrix_is_accepted_but_missing_trial_is_not(self):
        lines = []
        for variant in ("baseline", "candidate"):
            for store in ("main", "bound"):
                for edges in (1, 16, 1024):
                    for mode in ("steady", "dropped"):
                        for run in range(3):
                            prefix = f"{variant} run={run} store={store} edges={edges} mode={mode}"
                            lines.append(prefix + " median_ms=1 mad_ms=0 stmts=1 create_index=0 probe=0\n")
                            for op in ("neighbors_untyped", "neighbors_typed", "degree", "walk_depth2"):
                                lines.append(prefix + f" op={op} p50_us=1 p95_us=2\n")
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "trials.log"
            command = [sys.executable, str(ROOT / "scripts/analyze-graph-index-ddl-95.py"), str(log)]
            log.write_text("".join(lines))
            complete = subprocess.run(command, capture_output=True, text=True, timeout=15)
            self.assertEqual(complete.returncode, 0, complete.stderr)
            log.write_text("".join(lines[:-1]))
            incomplete = subprocess.run(command, capture_output=True, text=True, timeout=15)
            self.assertNotEqual(incomplete.returncode, 0)
            self.assertIn("Incomplete read matrix", incomplete.stderr)


if __name__ == "__main__":
    unittest.main()
