"""Check the pull-request path filter used by .github/workflows/ci.yml."""

from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci-changed-areas.py"


def run(*args, stdin=""):
    result = subprocess.run([sys.executable, str(SCRIPT), *args], input=stdin,
                            capture_output=True, text=True, check=True)
    return {k: v == "true" for k, v in (line.split("=") for line in result.stdout.split())}


def enabled(paths):
    return {job for job, on in run(stdin="\n".join(paths) + "\n").items() if on}


class ChangedAreasTests(unittest.TestCase):
    def test_all_enables_every_job(self):
        self.assertTrue(all(run("--all").values()))

    def test_core_scripts_and_workflows_enable_every_job(self):
        everything = set(run("--all"))
        for path in ("src/zova.zig", "include/zova.h", "build.zig", "LICENSE", "scripts/check-versions.sh",
                     ".github/workflows/ci.yml", "vendor/sqlite/sqlite3.c", "tests/README.md"):
            with self.subTest(path=path):
                self.assertEqual(enabled([path]), everything)

    def test_docs_only_enables_nothing(self):
        self.assertEqual(enabled(["notes/plan.md", "docs/extensions.md", "README.md", "API_STABILITY.md",
                                  ".github/release-notes/v1.0.0.md"]), set())
        self.assertEqual(enabled([]), set())

    def test_wasm_only(self):
        self.assertEqual(enabled(["bindings/wasm/src/index.ts", "README.md"]), {"wasm"})
        self.assertEqual(enabled([".github/workflows/wasm.yml"]), {"wasm"})

    def test_go_only(self):
        self.assertEqual(enabled(["bindings/go/zova.go"]), {"go", "plugin_packages"})

    def test_rust_enables_its_wrappers(self):
        self.assertEqual(enabled(["bindings/rust/zova/src/lib.rs"]),
                         {"rust", "rust_artifact", "python", "javascript", "plugin_packages"})

    def test_bindings_combine(self):
        self.assertEqual(enabled(["bindings/javascript/js/index.ts", "bindings/go/zova.go"]),
                         {"javascript", "go", "plugin_packages"})

    def test_any_core_path_wins(self):
        self.assertEqual(enabled(["bindings/wasm/README.md", "src/kv.zig"]), set(run("--all")))

    def test_prefix_must_be_a_directory(self):
        self.assertEqual(enabled(["bindings/gox/file"]), set(run("--all")))


if __name__ == "__main__":
    unittest.main()
