"""Conservative CI selection and workflow coverage contracts."""

import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ci_scope", ROOT / "scripts/ci_scope.py")
ci_scope = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci_scope)


class ScopeTests(unittest.TestCase):
    def test_docs_only_do_not_build_native_artifacts(self):
        scope = ci_scope.classify(["README.md", "docs/extensions.md", "notes/plan.md"])
        self.assertFalse(any(scope.values()))

    def test_binding_changes_select_consumers(self):
        for binding in ("go", "python", "javascript", "wasm"):
            with self.subTest(binding=binding):
                scope = ci_scope.classify([f"bindings/{binding}/src/example.c"])
                self.assertEqual({key for key, value in scope.items() if value}, {binding})
        scope = ci_scope.classify(["bindings/rust/zova/src/lib.rs"])
        self.assertEqual({key for key, value in scope.items() if value},
                         {"rust", "python", "javascript", "wasm"})

    def test_cross_binding_changes_combine_coverage(self):
        scope = ci_scope.classify(["bindings/go/zova.go", "bindings/python/src/lib.rs"])
        self.assertTrue(scope["go"])
        self.assertTrue(scope["python"])
        self.assertFalse(scope["native"])

    def test_core_build_headers_versions_and_unknown_files_require_full_ci(self):
        for path in ("src/graph.zig", "include/zova.h", "build.zig", "build.zig.zon",
                     "scripts/check-versions.sh", ".github/workflows/ci.yml",
                     "bindings/javascript/Cargo.toml", "bindings/go/go.mod",
                     "bindings/python/pyproject.toml", "bindings/wasm/package.json",
                     "vendor/sqlite3.53.4/sqlite3.c", "tests/fixtures/format-9.zova",
                     "bench/keyed_reads.zig", ".unknown", "bindings/new/file.py"):
            with self.subTest(path=path):
                self.assertTrue(all(ci_scope.classify([path]).values()))

    def test_deleted_paths_are_classified_without_reading_them(self):
        self.assertTrue(ci_scope.classify(["src/deleted.zig"])["native"])
        self.assertTrue(ci_scope.classify(["bindings/go/deleted.go"])["go"])

    def test_empty_or_release_events_fail_open_to_full_ci(self):
        self.assertTrue(all(ci_scope.classify([]).values()))
        for ref in ("main", "release/1.2.0", "refs/tags/v1.2.0"):
            self.assertTrue(all(ci_scope.classify(["README.md"], event="push", ref=ref).values()))
        self.assertTrue(all(ci_scope.classify(["README.md"], event="workflow_dispatch").values()))

    def test_invalid_git_base_runs_full_ci(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            result = subprocess.run(
                ["python3", str(ROOT / "scripts/ci_scope.py"), "classify", "--base", "0" * 40,
                 "--head", "HEAD", "--event", "pull_request", "--ref", "work/test",
                 "--output", str(output)], cwd=ROOT, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("full=true", output.read_text())

    def test_git_diff_includes_deletions_and_both_sides_of_renames(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            def git(*args):
                return subprocess.run(["git", "-C", str(root), *args], check=True,
                                      capture_output=True, text=True).stdout.strip()

            git("init")
            git("config", "user.name", "CI test")
            git("config", "user.email", "ci@example.invalid")
            (root / "src").mkdir()
            (root / "src/old.zig").write_text("// moved\n")
            (root / "src/deleted.zig").write_text("// deleted\n")
            git("add", ".")
            git("commit", "-m", "base")
            base = git("rev-parse", "HEAD")
            (root / "src/old.zig").rename(root / "README.md")
            (root / "src/deleted.zig").unlink()
            git("add", "-A")
            git("commit", "-m", "move and delete")
            output = root / "output"
            result = subprocess.run(
                ["python3", str(ROOT / "scripts/ci_scope.py"), "classify", "--base", base,
                 "--head", "HEAD", "--event", "pull_request", "--ref", "work/test",
                 "--output", str(output)], cwd=root, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("native=true", output.read_text())


class GateTests(unittest.TestCase):
    def results(self, scope):
        return {job: {"result": "success" if group is None or scope[group] else "skipped"}
                for job, group in ci_scope.JOB_GROUPS.items()}

    def test_deliberate_skips_pass_but_selected_skips_fail(self):
        scope = ci_scope.classify(["README.md"])
        self.assertEqual(ci_scope.gate_errors(scope, self.results(scope)), [])
        scope = ci_scope.classify(["src/graph.zig"])
        results = self.results(scope)
        results["zig"]["result"] = "skipped"
        self.assertTrue(ci_scope.gate_errors(scope, results))

    def test_failed_cancelled_missing_or_unexpected_jobs_fail(self):
        scope = ci_scope.classify(["README.md"])
        for status in ("failure", "cancelled", "unknown"):
            results = self.results(scope)
            results["static-check"]["result"] = status
            self.assertTrue(ci_scope.gate_errors(scope, results))
        results = self.results(scope)
        del results["changes"]
        self.assertTrue(ci_scope.gate_errors(scope, results))
        results = self.results(scope)
        results["new-job"] = {"result": "skipped"}
        self.assertTrue(ci_scope.gate_errors(scope, results))

    def test_malformed_scope_cannot_silently_skip_checks(self):
        with self.assertRaises(ValueError):
            ci_scope.gate_errors({}, {})
        scope = ci_scope.classify(["README.md"])
        scope["javascript"] = "false"
        with self.assertRaises(ValueError):
            ci_scope.gate_errors(scope, {})

    def test_gate_cli_returns_nonzero_on_selected_failure(self):
        scope = ci_scope.classify(["bindings/javascript/js/index.ts"])
        results = self.results(scope)
        results["javascript"]["result"] = "failure"
        result = subprocess.run(
            ["python3", str(ROOT / "scripts/ci_scope.py"), "gate", "--scope", json.dumps(scope),
             "--needs", json.dumps(results)], capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("javascript", result.stderr)


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = (ROOT / ".github/workflows/ci.yml").read_text()

    def job(self, name):
        start = self.workflow.index(f"  {name}:\n")
        end = re.search(r"^  [\w-]+:\n", self.workflow[start + 3:], re.M)
        return self.workflow[start:] if end is None else self.workflow[start:start + 3 + end.start()]

    def test_cli_is_not_executed_twice(self):
        self.assertNotIn("run: zig build cli-test", self.workflow)
        self.assertIn("run: zig build test\n", self.workflow)
        self.assertIn("run: zig build e2e", self.workflow)

    def test_static_checks_are_not_repeated_in_platform_jobs(self):
        self.assertEqual(self.workflow.count("run: zig fmt --check"), 1)
        self.assertEqual(self.workflow.count("bun run build:typescript"), 1)
        self.assertEqual(self.workflow.count("bun run typecheck"), 1)
        for job in ("zig", "rust", "python", "javascript-build", "javascript"):
            self.assertNotIn("cargo fmt", self.job(job))

    def test_javascript_runtime_jobs_download_instead_of_rebuild(self):
        build = self.job("javascript-build")
        runtime = self.job("javascript")
        self.assertNotIn("node-version: [", build)
        self.assertIn('node-version: ["22", "24"]', runtime)
        self.assertIn("actions/upload-artifact@v4", build)
        self.assertIn("actions/download-artifact@v4", runtime)
        self.assertNotIn("build:native", runtime)
        self.assertNotIn("cargo nextest", runtime)
        for target in ("linux-x86_64", "linux-arm64", "macos-x86_64", "macos-arm64", "windows-x86_64"):
            self.assertIn(target, build)
            self.assertIn(target, runtime)
        self.assertIn('"napi8"', (ROOT / "bindings/javascript/Cargo.toml").read_text())

    def test_final_gate_covers_every_job_and_runs_after_skips(self):
        gate = self.job("ci-gate")
        self.assertIn("if: always()", gate)
        for name in ci_scope.JOB_GROUPS:
            self.assertIn(name, gate)
        jobs = set(re.findall(r"^  ([\w-]+):\n", self.workflow.split("jobs:\n", 1)[1], re.M)) - {"ci-gate"}
        self.assertEqual(jobs, set(ci_scope.JOB_GROUPS))
        self.assertNotIn("paths-ignore:", self.workflow)

    def test_artifact_handoff_and_skip_conditions_are_explicit(self):
        static = self.job("static-check")
        runtime = self.job("javascript")
        build = self.job("javascript-build")
        self.assertIn("always() && !cancelled()", static)
        self.assertIn("needs: [changes, javascript-build]", static)
        self.assertIn("needs: [changes, javascript-build, static-check]", runtime)
        self.assertIn("name: ci-javascript-native-${{ matrix.target }}", build)
        self.assertIn("name: ci-javascript-native-${{ matrix.target }}", runtime)
        self.assertIn("name: ci-javascript-typescript", static)
        self.assertIn("name: ci-javascript-typescript", runtime)
        for path in ("bindings/javascript/index.js", "bindings/javascript/index.d.ts",
                     "bindings/javascript/*.node"):
            self.assertIn(path, build)
        for path in ("bindings/javascript/dist", "bindings/javascript/examples/dist"):
            self.assertIn(path, static)
        for job, group in ci_scope.JOB_GROUPS.items():
            if group:
                self.assertIn(f"if: needs.changes.outputs.{group} == 'true'", self.job(job))

    def test_packaging_abi_migration_and_platform_coverage_remains(self):
        for command in ("zig build check-storage-compat", "zig build c-abi-test",
                        "scripts/check-generated-c.sh", "scripts/check-native-c-abi.sh zig-out"):
            self.assertIn(command, self.workflow)
        self.assertIn("./.github/workflows/rust-artifact.yml", self.job("rust-artifact"))
        self.assertIn("./.github/workflows/wasm.yml", self.job("wasm"))
        self.assertIn('python-version: ["3.13", "3.14"]', self.job("python"))


if __name__ == "__main__":
    unittest.main()
