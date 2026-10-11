"""Keep the extension release gate connected to real distributed artifacts."""
from pathlib import Path
import unittest


ROOT = Path(__file__).parents[2]


class ExtensionReleaseGateTests(unittest.TestCase):
    def test_release_wheel_and_npm_tarball_execute_plugin_consumers(self):
        workflow = (ROOT / ".github/workflows/release-artifacts.yml").read_text()
        self.assertIn("bindings/python/tests/test_plugin_loading.py", workflow)
        self.assertIn("plugin-package-consumer.cjs", workflow)
        self.assertIn('steps.python313.outputs.python-path', workflow)
        self.assertIn('steps.python314.outputs.python-path', workflow)

    def test_author_examples_are_installed_and_executed(self):
        build = (ROOT / "build.zig").read_text()
        runner = (ROOT / "scripts/check-plugin-packages.py").read_text()
        self.assertIn('b.path("examples/plugin_query.c")', build)
        self.assertIn('"plugin_author_c"', runner)
        self.assertIn('"plugin_zig_fixture"', runner)
        self.assertIn('"author-cases.json"', runner)

    def test_source_package_includes_authoring_material(self):
        script = (ROOT / "scripts/package-release.sh").read_text()
        self.assertIn('cp -R examples "$TMP/$PKG/"', script)
        self.assertIn('! -path "$TMP/$PKG/docs/extension-authoring.md"', script)
        self.assertIn('! -path "$TMP/$PKG/examples/*.md"', script)

    def test_release_smoke_runs_both_reference_consumers(self):
        release = (ROOT / "scripts/check-release.sh").read_text()
        self.assertIn("scripts/check-extension-release.py", release)
        gate = (ROOT / "scripts/check-extension-release.py").read_text()
        for script in ("check-plugin-packages.py", "check-networkit-pagerank.py", "check-usearch-hnsw.py"):
            self.assertIn(script, gate)
        self.assertIn('"--packages"', gate)
        self.assertNotIn('"--bench"', gate)

    def test_actual_release_archive_loads_plugins(self):
        archive = (ROOT / "scripts/check-native-c-abi.sh").read_text()
        workflow = (ROOT / ".github/workflows/release-artifacts.yml").read_text()
        self.assertIn("ZOVA_TEST_PLUGIN_PACKAGES", archive)
        self.assertIn('"--native-prefix"', archive)
        self.assertIn("ZOVA_TEST_PLUGIN_PACKAGES", workflow)
        self.assertIn("--prepare-only", workflow)
        self.assertIn("--go", workflow)


if __name__ == "__main__":
    unittest.main()
