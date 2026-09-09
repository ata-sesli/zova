"""Keep the documented and published Python platform matrix aligned."""

from pathlib import Path
import ast
import re
import textwrap
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PythonPlatformMatrixTests(unittest.TestCase):
    def test_wheel_smoke_statements_close_before_database_cleanup(self):
        workflow = (ROOT / ".github/workflows/release-artifacts.yml").read_text()
        section = workflow[
            workflow.index("  python:\n") : workflow.index("  javascript-native:\n")
        ]
        snippets = re.findall(r"python - <<'PY'\n(.*?)\n          PY", section, re.S)
        self.assertEqual(len(snippets), 2, "Cover both Python wheel smoke tests")
        for index, snippet in enumerate(snippets):
            with self.subTest(smoke=index):
                tree = ast.parse(textwrap.dedent(snippet))
                prepares = [
                    node for node in ast.walk(tree)
                    if isinstance(node, ast.Call)
                    and isinstance(node.func, ast.Attribute)
                    and node.func.attr == "prepare"
                ]
                self.assertEqual(len(prepares), 1)
                scoped_prepares = [
                    item.context_expr
                    for node in ast.walk(tree) if isinstance(node, ast.With)
                    for item in node.items
                    if item.context_expr in prepares
                ]
                self.assertEqual(scoped_prepares, prepares,
                                 "Statement must use a context manager before temp cleanup")

    def test_python_snapshot_tools_do_not_require_rsync(self):
        for name in ("sync-rust-source.sh", "check-rust-source.sh"):
            script = (ROOT / "bindings/python/tools" / name).read_text()
            self.assertNotIn("rsync", script)

    def test_windows_x64_is_built_tested_and_published(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        artifacts = (ROOT / ".github/workflows/release-artifacts.yml").read_text()
        publish = (ROOT / ".github/workflows/publish-release.yml").read_text()

        python_ci = ci[ci.index("  python:\n") : ci.index("  javascript:\n")]
        self.assertIn("windows-latest", python_ci)

        python_artifacts = artifacts[
            artifacts.index("  python:\n") : artifacts.index("  javascript-native:\n")
        ]
        self.assertIn("platform: windows-x86_64", python_artifacts)
        self.assertIn("target: x86_64-pc-windows-msvc", python_artifacts)
        self.assertIn("cp313-abi3-win_amd64.whl", python_artifacts)

        match = re.search(r"expected_wheel_count=(\d+)", publish)
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), "5")

        version_check = (ROOT / "scripts/check-versions.sh").read_text()
        self.assertIn("expected_wheel_count=5", version_check)

    def test_python_metadata_and_docs_name_supported_operating_systems(self):
        metadata = tomllib.loads((ROOT / "bindings/python/pyproject.toml").read_text())
        classifiers = metadata["project"]["classifiers"]
        self.assertNotIn("Operating System :: OS Independent", classifiers)
        self.assertIn("Operating System :: Microsoft :: Windows", classifiers)
        self.assertIn("Operating System :: MacOS", classifiers)
        self.assertIn("Operating System :: POSIX :: Linux", classifiers)

        readme = (ROOT / "README.md").read_text()
        self.assertIn("Linux/macOS", readme)
        self.assertIn("Windows x86_64", readme)
        self.assertNotIn(
            "Python wheels outside the current Linux/macOS x86_64/arm64 CPython",
            readme,
        )

        python_readme = (ROOT / "bindings/python/README.md").read_text()
        self.assertIn("Windows x86_64", python_readme)


if __name__ == "__main__":
    unittest.main()
