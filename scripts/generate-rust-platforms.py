"""Generate explicit platform source crates; no consumer-side downloads or Zig."""
from pathlib import Path
import shutil
import subprocess
import sys
import platform

PLATFORMS = {
    "linux-x64": "x86_64-unknown-linux-gnu",
    "linux-arm64": "aarch64-unknown-linux-gnu",
    "darwin-x64": "x86_64-apple-darwin",
    "darwin-arm64": "aarch64-apple-darwin",
    "windows-x64": "x86_64-pc-windows-msvc",
}

if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    fixtures = root / "bindings/rust/zova/tests/fixtures"
    fixtures.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / "tests/fixtures/format-9.zova", fixtures / "format-9.zova")
    names = sys.argv[1:]
    if names == ["--host"]:
        os_name = {"Darwin": "darwin", "Linux": "linux", "Windows": "windows"}[platform.system()]
        arch = "arm64" if platform.machine().lower() in ("aarch64", "arm64") else "x64"
        names = [f"{os_name}-{arch}"]
    for name in names or PLATFORMS:
        target = PLATFORMS[name]
        package = root / "bindings/rust" / f"zova-sys-{name}"
        print(f"Generating {name}: {target}", flush=True)
        subprocess.run(["sh", str(root / "scripts/update-generated-c.sh"), str(package / "native"), target], check=True)
        shutil.copy2(root / "LICENSE", package / "LICENSE")
