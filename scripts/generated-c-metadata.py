"""Record provenance and hashes for an explicitly targeted generated-C bundle."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

root, output = map(Path, sys.argv[1:3])
target, sqlite = sys.argv[3:5]
version = re.search(r'pub const package_version\s*=\s*"([^"]+)"', (root / "src/version.zig").read_text())[1]
(output / "cargo-target.txt").write_text(target + "\n")
(output / "version.txt").write_text(version + "\n")
commit = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], text=True, capture_output=True)
metadata = {
    "zova_version": version,
    "source_commit": commit.stdout.strip() if commit.returncode == 0 else "unavailable (source archive)",
    "zig_version": subprocess.check_output(["zig", "version"], text=True).strip(),
    "cargo_target": target,
    "sqlite_version": sqlite,
    "sqlite_defines": ["SQLITE_THREADSAFE=1", "SQLITE_ENABLE_FTS5", "SQLITE_ENABLE_DBSTAT_VTAB",
                       "SQLITE_ENABLE_RTREE", "SQLITE_ENABLE_GEOPOLY", "SQLITE_ENABLE_CARRAY",
                       "SQLITE_ENABLE_MATH_FUNCTIONS"],
    "sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(output.iterdir()) if p.is_file()},
}
(output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
