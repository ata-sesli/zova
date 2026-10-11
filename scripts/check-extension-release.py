"""Run the bounded native extension acceptance gate; no benchmarks/publication."""
import argparse
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    packages = out / "packages"
    commands = [
        [sys.executable, "scripts/check-plugin-packages.py", packages],
        [sys.executable, "scripts/check-networkit-pagerank.py", out / "pagerank", "--packages", packages],
        [sys.executable, "scripts/check-usearch-hnsw.py", out / "usearch", "--packages", packages],
    ]
    for index, command in enumerate(commands, 1):
        print(f"Extension release gate {index}/{len(commands)}: {command[1]}", flush=True)
        subprocess.run(list(map(str, command)), cwd=ROOT, check=True)
    print("Extension release gate passed: generated C, Rust, Go, installed wheel/npm, both references", flush=True)


if __name__ == "__main__":
    main()
