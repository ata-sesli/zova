"""Keep the documented and published Python platform matrix aligned."""

from pathlib import Path
import re
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PythonPlatformMatrixTests(unittest.TestCase):
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
