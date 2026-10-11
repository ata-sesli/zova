"""Build and check the isolated USearch reference (two jobs, one ANN thread).

--bench: 2048 vectors x 32 dimensions, one warmup, three build/incremental
samples and 40 search queries. No large repository or unbounded benchmark.
Use an external output directory locally; dependencies are never vendored.
"""
import argparse
import os
from pathlib import Path
import platform
import runpy
import sqlite3
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def run(command, env, cwd=ROOT):
    print("+ " + " ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=cwd, env=env, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--packages", type=Path)
    parser.add_argument("--library", type=Path, help="reuse a checked static C ABI locally")
    parser.add_argument("--cli", type=Path, help="reuse its matching CLI locally")
    parser.add_argument("--usearch-source", type=Path, help="already hash-verified upstream extraction")
    parser.add_argument("--bench", action="store_true")
    parser.add_argument("--sanitize", action="store_true")
    args = parser.parse_args()
    if bool(args.library) != bool(args.cli):
        parser.error("--library and --cli must be supplied together")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    env = os.environ.copy()
    env.setdefault("ZIG_GLOBAL_CACHE_DIR", str(out / "zig-global"))
    env.setdefault("ZIG_LOCAL_CACHE_DIR", str(out / "zig-local"))
    env.setdefault("CARGO_BUILD_JOBS", "2")
    env.setdefault("GOFLAGS", "-p=2")
    env["TMPDIR"] = str(out / "tmp")
    Path(env["TMPDIR"]).mkdir()
    system = platform.system()
    packages = args.packages.resolve() if args.packages else None
    print("1/4: C ABI host (two jobs, existing caches)", flush=True)
    if args.library:
        library, cli = args.library.resolve(), args.cli.resolve()
    else:
        host = out / "host"
        run(["zig", "build", "install", "c-abi", "-Doptimize=ReleaseSafe", "-j2", "--summary", "all",
             "--cache-dir", env["ZIG_LOCAL_CACHE_DIR"], "--prefix", host], env)
        library = host / "lib/libzova_c.a"
        cli = host / "bin" / ("zova.exe" if system == "Windows" else "zova")
    runtime = None
    if packages and not args.library:
        library = out / ("zova_c.lib" if system == "Windows" else "libzova_c.a")
        run(["zig", "ar", "rcs", library, packages / "zova.o", packages / "sqlite.o"], env)
        if system == "Windows":
            helper = runpy.run_path(str(ROOT / "scripts/check-networkit-pagerank.py"))
            runtime = helper["build_windows_compiler_runtime"](out, env)
    print("2/4: Pinned portable USearch (SIMD dependencies/OpenMP disabled)", flush=True)
    build = out / "build"
    configure = ["cmake", "-S", ROOT / "examples/usearch-hnsw", "-B", build, "-G", "Ninja",
                 "-DCMAKE_BUILD_TYPE=Release", f"-DZOVA_C_ABI_LIBRARY={library}",
                 f"-DFETCHCONTENT_BASE_DIR={out / 'dependencies'}"]
    if args.usearch_source:
        configure.append(f"-DFETCHCONTENT_SOURCE_DIR_USEARCH={args.usearch_source.resolve()}")
    if runtime:
        configure.append(f"-DZOVA_COMPILER_RT_LIBRARY={runtime}")
    if args.sanitize:
        if system == "Windows":
            raise RuntimeError("sanitizer runner is supported with Clang on Unix")
        configure += ["-DCMAKE_CXX_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer -g",
                      "-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=address,undefined",
                      "-DCMAKE_SHARED_LINKER_FLAGS=-fsanitize=address,undefined"]
    run(configure, env)
    run(["cmake", "--build", build, "--parallel", "2"], env)
    run(["cmake", "--install", build, "--prefix", out / "installed"], env)
    bundle = out / "installed/usearch.zovaext"
    test = build / ("usearch_test.exe" if system == "Windows" else "usearch_test")
    database, trust = out / "main.zova", out / "trust.json"
    print("3/4: Incremental/rollback/snapshot/reopen/fault checks", flush=True)
    run([build / ("usearch_faults.exe" if system == "Windows" else "usearch_faults")], env)
    run([test, bundle, database, trust] + (["bench"] if args.bench else []), env)
    if not args.sanitize:
        # The plain C restore request has no external registry. Use the existing
        # registry-aware CLI, with default verification, not an unchecked copy.
        restored = out / "restored.zova"
        run([cli, "--extension", bundle, "restore", str(database) + ".backup.zova", restored],
            {**env, "ZOVA_TRUST_STORE": str(trust)})
        run([test, bundle, restored, trust, "check"], env)
    bound = out / "bound.zova"
    run([test, bundle, bound, trust, "create"], env)
    run([cli, "vector-store", "create", out / "vectors.zova"], env)
    with sqlite3.connect(out / "vectors.zova") as store:
        store.execute("PRAGMA journal_mode=WAL")
    run([cli, "vector-store", "bind", bound, out / "vectors.zova"], env)
    run([test, bundle, bound, trust, "bound"], env)
    print(f"FINAL_DATABASE_BYTES {database.stat().st_size}", flush=True)
    if not packages:
        print("Native checks passed; installed binding checks require --packages", flush=True)
        return
    print("4/4: Real safe Rust/Go/installed Python/npm consumers", flush=True)
    env.update(ZOVA_USEARCH_BUNDLE=str(bundle), ZOVA_USEARCH_TRUST=str(trust), ZOVA_USEARCH_DATABASE=str(database))
    env.setdefault("CARGO_TARGET_DIR", str(packages / "cargo"))
    run(["cargo", "nextest", "run", "-p", "zova", "--test", "usearch_hnsw", "--run-ignored", "all",
         "--manifest-path", "bindings/rust/Cargo.toml"], env)
    generated = packages / ("go-generated" if system == "Windows" else "generated")
    go_env = {**env, "CGO_ENABLED": "1", "CGO_CFLAGS": f"-I{generated.as_posix()}",
              "CGO_LDFLAGS": f"-L{(packages / 'lib').as_posix()}" + (" -lntdll" if system == "Windows" else ""),
              "GOCACHE": str(packages / "go-cache")}
    run(["go", "test", "-count=1", "-run", "TestUSearchSQL", "./..."], go_env, ROOT / "bindings/go")
    python = packages / "python-env" / ("Scripts/python.exe" if system == "Windows" else "bin/python")
    run([python, ROOT / "bindings/python/tests/usearch_consumer.py"], env, out)
    for js in ("node", "bun"):
        run([js, ROOT / "bindings/javascript/tests/usearch-consumer.cjs"], env, packages / "npm-consumer")
    print("All USearch native/plugin binding checks passed", flush=True)


if __name__ == "__main__":
    main()
