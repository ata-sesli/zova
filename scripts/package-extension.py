"""Archive one built reference extension bundle for an independent extension release."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import tarfile

# name -> directory under check-extension-release.py's output
EXTENSIONS = {"networkit": "pagerank", "usearch": "usearch"}
SYSTEMS = {"Linux": "linux", "Darwin": "macos", "Windows": "windows"}
MACHINES = {"x86_64": "x86_64", "amd64": "x86_64", "arm64": "arm64", "aarch64": "arm64"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("name", choices=sorted(EXTENSIONS))
    parser.add_argument("gate_output", type=Path, help="successful check-extension-release.py output")
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    bundle = args.gate_output / EXTENSIONS[args.name] / "installed" / f"{args.name}.zovaext"
    manifest = json.loads((bundle / "extension.json").read_text())
    if manifest["name"] != args.name or not (bundle / manifest["library"]).is_file():
        raise SystemExit(f"incomplete bundle: {bundle}")
    target = f"{SYSTEMS[platform.system()]}-{MACHINES[platform.machine().lower()]}"
    args.destination.mkdir(parents=True, exist_ok=True)
    archive = args.destination / f"zova-extension-{args.name}-v{manifest['version']}-{target}.tar.gz"
    with tarfile.open(archive, "w:gz") as output:
        output.add(bundle, arcname=bundle.name)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_name(archive.name + ".sha256").write_text(f"{digest}  {archive.name}\n")
    print(f"{archive.name} sha256={digest} zova_abi_min={manifest['zova_abi_min']}", flush=True)


if __name__ == "__main__":
    main()
