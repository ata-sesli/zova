"""Check trial arguments without running storage benchmarks."""

from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ObjectIngestionRunnerTests(unittest.TestCase):
    def run_fixture(self, reported_size='"$3"'):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for variant in ("base", "cand"):
                directory = root / variant / "bin"
                directory.mkdir(parents=True)
                # Include the obsolete name so a missing binary cannot hide
                # the original defect: baseline omitted the size argument.
                for name in ("zova_object_ingestion_benchmark", "zova_object_ingestion_93_benchmark"):
                    binary = directory / name
                    binary.write_text(
                        '#!/bin/sh\n[ "$#" -eq 3 ] || exit 42\n'
                        f'printf "profile=%s bytes=%s fresh_ms=1\\n" "$2" {reported_size} >&2\n'
                    )
                    binary.chmod(0o755)
            return subprocess.run(
                ["sh", str(ROOT / "scripts/bench-object-ingestion-93.sh"), str(root)],
                capture_output=True, text=True, timeout=15,
            )

    def test_both_variants_receive_each_requested_size(self):
        result = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        for size in (1048576, 8388608):
            self.assertEqual(result.stdout.count(f"bytes={size} "), 32)

    def test_misreported_fixture_size_is_rejected(self):
        result = self.run_fixture("999")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
