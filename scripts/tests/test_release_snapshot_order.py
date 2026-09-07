"""Exercise release preflight with real version validation and fake builds."""
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ReleaseSnapshotOrderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zova-release-order-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        # Export tracked inputs only, including the current uncommitted script.
        with subprocess.Popen(
            ["git", "archive", "HEAD"], cwd=ROOT, stdout=subprocess.PIPE
        ) as archive:
            with tarfile.open(fileobj=archive.stdout, mode="r|") as contents:
                contents.extractall(self.root, filter="data")
            self.assertEqual(archive.wait(), 0)
        shutil.copy2(ROOT / "scripts/check-release.sh", self.root / "scripts/check-release.sh")
        self.assertFalse((self.root / "bindings/python/rust").exists())
        self.assertFalse((self.root / "bindings/rust/zova-sys/native/generated").exists())
        tools = self.root / "fake-tools"
        tools.mkdir()
        for command in ("zig", "cargo", "go", "uv", "bun", "node", "npm", "emcc"):
            script = tools / command
            script.write_text("#!/bin/sh\nexit " + ("73" if command == "zig" else "0") + "\n")
            script.chmod(0o755)
        self.env = {**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"], "CI": "true"}
        self.env.pop("HELIUM_EXECUTABLE", None)
        self.write_script("bindings/rust/zova-sys/tools/sync-native-source.sh", "mkdir -p bindings/rust/zova-sys/native/generated\n")
        self.write_script("bindings/rust/zova-sys/tools/check-native-source.sh", "test -d bindings/rust/zova-sys/native/generated\n")
        self.write_script("bindings/python/tools/sync-rust-source.sh", '''
mkdir -p bindings/python/rust/zova bindings/python/rust/zova-sys/tests
cp bindings/rust/zova/Cargo.toml bindings/python/rust/zova/Cargo.toml
sed -n '/^version = /p' bindings/rust/Cargo.toml > bindings/python/rust/zova-sys/Cargo.toml
cp bindings/rust/zova-sys/tests/abi.rs bindings/python/rust/zova-sys/tests/abi.rs
if [ "${STALE_SNAPSHOT:-}" = 1 ]; then
    printf 'version = "0.0.0"\\n' > bindings/python/rust/zova-sys/Cargo.toml
fi
''')
        self.write_script("bindings/python/tools/check-rust-source.sh", '''
test -f bindings/python/rust/zova-sys/Cargo.toml
if [ "${REJECT_SNAPSHOT:-}" = 1 ]; then exit 42; fi
''')

    def write_script(self, path, content):
        (self.root / path).write_text("#!/bin/sh\nset -eu\n" + content)

    def run_release(self, **env):
        return subprocess.run(
            ["sh", "scripts/check-release.sh"], cwd=self.root,
            env={**self.env, **env}, text=True, capture_output=True,
        )

    def test_clean_export_prepares_snapshots_before_version_check(self):
        missing = subprocess.run(
            ["sh", "scripts/check-versions.sh"], cwd=self.root,
            text=True, capture_output=True,
        )
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("bindings/python/rust", missing.stdout + missing.stderr)
        result = self.run_release()
        self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
        self.assertIn("version check ok:", result.stdout)

    def test_stale_synchronized_version_is_rejected(self):
        result = self.run_release(STALE_SNAPSHOT="1")
        self.assertNotEqual(result.returncode, 73)
        self.assertIn("bindings/python/rust/zova-sys/Cargo.toml", result.stdout + result.stderr)

    def test_snapshot_verification_failure_stops_preflight(self):
        result = self.run_release(REJECT_SNAPSHOT="1")
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertNotIn("version check ok:", result.stdout)


if __name__ == "__main__":
    unittest.main()
