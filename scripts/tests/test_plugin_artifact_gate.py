"""Keep real-plugin checks on extracted Rust artifacts, not source overrides."""
from pathlib import Path
import unittest


class PluginArtifactGate(unittest.TestCase):
    def test_immutable_rust_artifacts_execute_the_plugin_fixture_test(self):
        workflow = (Path(__file__).parents[2] / ".github/workflows/rust-artifact.yml").read_text()
        self.assertIn("--prepare-only", workflow)
        self.assertIn('"plugin_loading"', workflow)
        self.assertIn('"--run-ignored", "all"', workflow)
        self.assertIn('"platform-patches.toml"', workflow)
        self.assertIn('"bindings/rust" / f"zova-{version}"', workflow)


if __name__ == "__main__":
    unittest.main()
