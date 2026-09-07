import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest


SCRIPT = Path(__file__).parents[1] / "check-rust-artifact.py"
SPEC = importlib.util.spec_from_file_location("check_rust_artifact", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class PublishBodyTests(unittest.TestCase):
    def test_release_workflow_publishes_verified_archives_directly(self):
        workflow = (
            Path(__file__).parents[2] / ".github/workflows/publish-release.yml"
        ).read_text()

        self.assertNotIn("cargo publish", workflow)
        self.assertIn(
            'scripts/check-rust-artifact.py publish "$artifact" "$crate"',
            workflow,
        )
        self.assertIn(
            'scripts/check-rust-artifact.py publish "$artifact" zova-sys',
            workflow,
        )
        self.assertIn(
            'scripts/check-rust-artifact.py publish "$artifact" zova',
            workflow,
        )

    def test_publish_body_contains_exact_crate_bytes(self):
        metadata = {"name": "example", "vers": "1.2.3", "deps": []}
        crate = b"\x1f\x8bverified-crate-bytes\x00\xff"

        body = MODULE.build_publish_body(metadata, crate)

        metadata_size = struct.unpack_from("<I", body)[0]
        metadata_start = 4
        metadata_end = metadata_start + metadata_size
        self.assertEqual(json.loads(body[metadata_start:metadata_end]), metadata)
        crate_size = struct.unpack_from("<I", body, metadata_end)[0]
        crate_start = metadata_end + 4
        self.assertEqual(crate_size, len(crate))
        self.assertEqual(body[crate_start:], crate)

    def test_publish_metadata_uses_normalized_packaged_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            readme = root / "README.md"
            readme.write_text("# Exact package\n")
            package = {
                "name": "example",
                "version": "1.2.3",
                "authors": ["Example Author"],
                "description": "Example crate",
                "documentation": "https://docs.rs/example",
                "homepage": None,
                "readme": str(readme),
                "keywords": ["example"],
                "categories": ["database"],
                "license": "MIT",
                "license_file": None,
                "repository": "https://example.invalid/repo",
                "rust_version": "1.79",
                "links": None,
                "features": {"default": []},
                "dependencies": [
                    {
                        "name": "actual-package",
                        "req": "^2",
                        "kind": "build",
                        "rename": "alias-name",
                        "optional": True,
                        "uses_default_features": False,
                        "features": ["feature-a"],
                        "target": "cfg(unix)",
                        "registry": None,
                    }
                ],
            }

            metadata = MODULE.publish_metadata(package)

        self.assertEqual(metadata["name"], "example")
        self.assertEqual(metadata["vers"], "1.2.3")
        self.assertEqual(metadata["readme"], "# Exact package\n")
        self.assertEqual(metadata["readme_file"], "README.md")
        self.assertEqual(
            metadata["deps"],
            [
                {
                    "name": "actual-package",
                    "version_req": "^2",
                    "features": ["feature-a"],
                    "optional": True,
                    "default_features": False,
                    "target": "cfg(unix)",
                    "kind": "build",
                    "registry": None,
                    "explicit_name_in_toml": "alias-name",
                }
            ],
        )


if __name__ == "__main__":
    unittest.main()
