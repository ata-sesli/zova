"""Build/test the isolated PageRank reference; optional installed-package checks.

Only nine upstream C++ files, two build jobs, one compute thread. --bench runs
one warmup and three measured calls on 2048 nodes / 8192 edges, never a full
repository or large storage benchmark. The output directory must be new.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import sqlite3
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def run(command, env, cwd=ROOT):
    print("+ " + " ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), env=env, cwd=cwd, check=True)


def build_windows_compiler_runtime(out, env):
    # zig cc supplies builtins when linking; MSVC's link.exe does not.
    zig_env = subprocess.check_output(["zig", "env"], env=env, text=True)
    lib_dir = re.search(r'\.lib_dir\s*=\s*("(?:[^"\\]|\\.)*")', zig_env)
    if not lib_dir:
        raise RuntimeError("could not determine Zig lib_dir")
    source = Path(json.loads(lib_dir.group(1))) / "compiler_rt.zig"
    runtime = out / "compiler_rt.lib"
    # Without -fno-builtin LLVM turns the runtime's own memcpy loop into a
    # memcpy call, which recurses once per 16 bytes and overflows on large copies.
    run(["zig", "build-lib", source, "-target", "x86_64-windows-msvc",
         "-O", "ReleaseFast", "-fno-builtin", f"-femit-bin={runtime}"], env)
    return runtime


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--packages", type=Path,
                        help="successful check-plugin-packages.py output for real binding consumers")
    parser.add_argument("--bench", action="store_true")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    env = os.environ.copy()
    env.setdefault("ZIG_GLOBAL_CACHE_DIR", str(out / "zig-global"))
    env.setdefault("ZIG_LOCAL_CACHE_DIR", str(out / "zig-local"))
    env.setdefault("CARGO_BUILD_JOBS", "2")
    env.setdefault("GOFLAGS", "-p=2")
    env["TMPDIR"] = str(out / "tmp")
    Path(env["TMPDIR"]).mkdir()
    packages = args.packages.resolve() if args.packages else None
    system = platform.system()
    if system == "Windows" and not packages:
        raise RuntimeError("Windows requires --packages from the native package runner")
    print("1/4: Build host/CLI with two jobs", flush=True)
    host = out / "host"
    run(["zig", "build", "install", "c-abi", "-Doptimize=ReleaseSafe", "-j2", "--summary", "all",
         "--cache-dir", env["ZIG_LOCAL_CACHE_DIR"], "--prefix", host], env)
    library = host / "lib/libzova_c.a"
    runtime = None
    if packages:
        library = out / ("zova_c.lib" if system == "Windows" else "libzova_c.a")
        run(["zig", "ar", "rcs", library, packages / "zova.o", packages / "sqlite.o"], env)
        if system == "Windows":
            # Keep the checked generated-C objects and add the matching runtime
            # as a separate library, rather than nesting an archive inside one.
            runtime = build_windows_compiler_runtime(out, env)
    print("2/4: Build pinned NetworKit PageRank subset with two jobs", flush=True)
    build = out / "build"
    configure = ["cmake", "-S", ROOT / "examples/networkit-pagerank", "-B", build,
                 "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release", f"-DZOVA_C_ABI_LIBRARY={library}",
                 f"-DFETCHCONTENT_BASE_DIR={out / 'dependencies'}"]
    if runtime:
        configure.append(f"-DZOVA_COMPILER_RT_LIBRARY={runtime}")
    if system == "Darwin":
        omp = Path(subprocess.check_output(["brew", "--prefix", "libomp"], text=True).strip())
        configure += [f"-DOpenMP_CXX_FLAGS=-Xpreprocessor -fopenmp -I{omp / 'include'}",
                      "-DOpenMP_CXX_LIB_NAMES=omp", f"-DOpenMP_omp_LIBRARY={omp / 'lib/libomp.dylib'}"]
    run(configure, env)
    run(["cmake", "--build", build, "--parallel", "2"], env)
    run(["cmake", "--install", build, "--prefix", out / "installed"], env)
    bundle = out / "installed/networkit.zovaext"
    manifest = json.loads((bundle / "extension.json").read_text())
    # OpenMP is a shared toolchain runtime, not a private duplicate in each
    # bundle. Multiple libomp copies can abort an application already using it.
    test = build / ("pagerank_test.exe" if system == "Windows" else "pagerank_test")
    faults = build / ("pagerank_faults.exe" if system == "Windows" else "pagerank_faults")
    cli = host / "bin" / ("zova.exe" if system == "Windows" else "zova")
    trust = out / "trust.json"
    database = out / "main.zova"
    print("3/4: Semantics, resource limits, snapshots, bound routing and lifecycle", flush=True)
    run([faults, bundle / manifest["library"]], env)
    run([test, bundle, database, trust, "bench"] if args.bench else [test, bundle, database, trust], env)
    bound = out / "bound.zova"
    run([test, bundle, bound, trust, "create"], env)
    run([cli, "graph-store", "create", out / "graphs.zova"], env)
    # Configure WAL before binding so the snapshot fixture does not change the
    # attached source's journal mode while another connection is reading it.
    with sqlite3.connect(out / "graphs.zova") as graph_store:
        graph_store.execute("PRAGMA journal_mode=WAL")
    run([cli, "graph-store", "bind", bound, out / "graphs.zova"], env)
    run([test, bundle, bound, trust, "bound"], env)
    if not packages:
        print("Native reference checks passed; installed-package checks require --packages", flush=True)
        return
    print("4/4: Safe Rust, Go and installed wheel/npm SQL consumers", flush=True)
    env.update(ZOVA_PAGERANK_BUNDLE=str(bundle), ZOVA_PAGERANK_TRUST=str(trust),
               ZOVA_PAGERANK_DATABASE=str(database))
    env.setdefault("CARGO_TARGET_DIR", str(packages / "cargo"))
    run(["cargo", "nextest", "run", "-p", "zova", "--test", "networkit_pagerank",
         "--run-ignored", "all", "--manifest-path", "bindings/rust/Cargo.toml"], env)
    generated = packages / ("go-generated" if system == "Windows" else "generated")
    go_env = {**env, "CGO_ENABLED": "1", "CGO_CFLAGS": f"-I{generated.as_posix()}",
              "CGO_LDFLAGS": f"-L{(packages / 'lib').as_posix()}" + (" -lntdll" if system == "Windows" else ""),
              "GOCACHE": str(packages / "go-cache")}
    run(["go", "test", "-count=1", "-run", "TestNetworKitPageRankSQL", "./..."], go_env, ROOT / "bindings/go")
    python = packages / "python-env" / ("Scripts/python.exe" if system == "Windows" else "bin/python")
    run([python, ROOT / "bindings/python/tests/networkit_pagerank_consumer.py"], env, out)
    for runtime in ("node", "bun"):
        run([runtime, ROOT / "bindings/javascript/tests/networkit-pagerank-consumer.cjs"], env, packages / "npm-consumer")
    print("All native PageRank reference and binding checks passed", flush=True)


if __name__ == "__main__":
    main()
