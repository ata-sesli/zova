#!/usr/bin/env python3
"""Turn a copy of bindings/go into the module that a release tag publishes.

The released module carries zova.h and one prebuilt libzova_c.a per platform
under native/, and builds with cgo_prebuilt.go by default, so `go get` alone
is enough to build it. The source checkout is unchanged: it keeps
cgo_checkout.go and links ../../zig-out/lib.

    prepare-go-module.py <module-dir> --lib linux_amd64=<libzova_c.a or C ABI .tar.gz> ... [--check]

Each --lib names a Go GOOS_GOARCH and either a static library or a release
C ABI archive that contains lib/libzova_c.a. --check then builds and runs
examples/basic from a separate consumer module against the prepared copy with
no CGO_CFLAGS or CGO_LDFLAGS, as a `go get` user would. It needs the host
platform among the --lib entries.
"""

import argparse
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLATFORMS = {"darwin_amd64", "darwin_arm64", "linux_amd64", "linux_arm64", "windows_amd64"}
CHECKOUT_CONSTRAINT = "//go:build !zova_prebuilt && !zova_external\n"
PREBUILT_CONSTRAINT = "//go:build zova_prebuilt && !zova_external\n"


def copy_library(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.name.endswith(".tar.gz"):
        with tarfile.open(source) as archive:
            members = [m for m in archive.getmembers() if m.isfile() and m.name.endswith("/lib/libzova_c.a")]
            if len(members) != 1:
                raise SystemExit(f"{source}: expected one lib/libzova_c.a, found {len(members)}")
            with archive.extractfile(members[0]) as data, open(destination, "wb") as out:
                shutil.copyfileobj(data, out)
    else:
        shutil.copyfile(source, destination)


def prepare(module, libraries):
    checkout, prebuilt = module / "cgo_checkout.go", module / "cgo_prebuilt.go"
    if not checkout.read_text().startswith(CHECKOUT_CONSTRAINT) or not prebuilt.read_text().startswith(PREBUILT_CONSTRAINT):
        raise SystemExit(f"{module}: cgo_checkout.go or cgo_prebuilt.go has unexpected build constraints")
    include = module / "native/include"
    include.mkdir(parents=True, exist_ok=True)
    for header in ("zova.h", "zova_plugin.h"):
        shutil.copyfile(ROOT / "include" / header, include / header)
    for target, source in sorted(libraries.items()):
        copy_library(source, module / "native" / target / "libzova_c.a")
        print(f"{target}: {(module / 'native' / target / 'libzova_c.a').stat().st_size} bytes", flush=True)
    checkout.unlink()
    prebuilt.write_text("//go:build !zova_external\n" + prebuilt.read_text()[len(PREBUILT_CONSTRAINT):])


def host_target():
    system = {"Linux": "linux", "Darwin": "darwin", "Windows": "windows"}[platform.system()]
    machine = {"x86_64": "amd64", "AMD64": "amd64", "aarch64": "arm64", "arm64": "arm64"}[platform.machine()]
    return f"{system}_{machine}"


def check(module):
    module_path = (module / "go.mod").read_text().split()[1]
    env = {k: v for k, v in os.environ.items() if k not in ("CGO_CFLAGS", "CGO_LDFLAGS", "CGO_CPPFLAGS")}
    env["CGO_ENABLED"] = "1"
    with tempfile.TemporaryDirectory(prefix="zova-go-consumer-") as consumer:
        consumer = Path(consumer)
        shutil.copyfile(module / "examples/basic/main.go", consumer / "main.go")
        (consumer / "go.mod").write_text(
            f"module example.com/zova-consumer\n\ngo 1.22\n\nrequire {module_path} v0.0.0\n\n"
            f"replace {module_path} => {module.resolve().as_posix()}\n")
        print("+ go run . (consumer module, no CGO_CFLAGS/CGO_LDFLAGS)", flush=True)
        subprocess.run(["go", "run", "."], cwd=consumer, env=env, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("module", type=Path, help="a copy of bindings/go to modify in place")
    parser.add_argument("--lib", action="append", default=[], metavar="GOOS_GOARCH=PATH", required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.module.resolve() == (ROOT / "bindings/go").resolve():
        raise SystemExit("refusing to modify the checkout's bindings/go; pass a copy")
    libraries = {}
    for entry in args.lib:
        target, _, path = entry.partition("=")
        if target not in PLATFORMS or not path:
            raise SystemExit(f"--lib {entry}: expected one of {sorted(PLATFORMS)}=PATH")
        libraries[target] = Path(path)
    prepare(args.module, libraries)
    if args.check:
        if host_target() not in libraries:
            raise SystemExit(f"--check needs a --lib for the host platform {host_target()}")
        check(args.module)
    return 0


if __name__ == "__main__":
    sys.exit(main())
