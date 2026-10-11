"""Bounded native-package plugin check. No publication or default trust changes.

Builds two small plugin bundles and a generated-C host once. --prepare-only
stops after the C ABI/trust/dependency checks and exports fixture paths for CI.
The full run also checks Rust, Go, an installed Python wheel and npm tarball.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
SYSTEM = platform.system()
SUFFIX = {"Darwin": ".dylib", "Linux": ".so", "Windows": ".dll"}[SYSTEM]


def run(args, *, cwd=ROOT, env=None):
    print("+ " + " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)


def one_library(prefix, name):
    matches = [p for p in prefix.rglob("*" + name + "*" + SUFFIX) if p.is_file()]
    if len(matches) != 1:
        raise RuntimeError(f"expected one {name} library, found {matches}")
    return matches[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--resume-consumers", action="store_true",
                        help="reuse a successfully prepared run for Go/wheel/npm checks")
    args = parser.parse_args()
    out = args.output.resolve()
    if not args.resume_consumers:
        out.mkdir(parents=True, exist_ok=False)  # Never overwrite another run.
    env = os.environ.copy()
    env.setdefault("CARGO_BUILD_JOBS", "2")
    env.setdefault("CARGO_TARGET_DIR", str(out / "cargo"))
    env.setdefault("ZIG_GLOBAL_CACHE_DIR", str(out / "zig-global"))
    env.setdefault("ZIG_LOCAL_CACHE_DIR", str(out / "zig-local"))
    env.setdefault("GOCACHE", str(out / "go-cache"))
    env.setdefault("UV_CACHE_DIR", str(out / "uv-cache"))
    env["TMPDIR"] = str(out / "tmp")
    Path(env["TMPDIR"]).mkdir(exist_ok=args.resume_consumers)
    # Exercise the normal generated-C package path, not an archive override.
    for key in ("ZOVA_LIB_DIR", "ZOVA_INCLUDE_DIR", "ZOVA_SOURCE_DIR"):
        env.pop(key, None)
    if args.resume_consumers:
        cases = [(Path(p), Path(t)) for p, t in json.loads((out / "cases.json").read_text())]
        check_consumers(out, env, cases)
        return
    print("1/5: Build real C/C++ bundles (two jobs)", flush=True)
    run(["zig", "build", "plugin-package-fixtures", "-Doptimize=ReleaseSafe", "-j2", "--summary", "all", "--cache-dir", env["ZIG_LOCAL_CACHE_DIR"], "--prefix", out / "fixtures"], env=env)
    generated = out / "generated"
    run(["sh", "scripts/update-generated-c.sh", generated], env=env)
    cc = ["zig", "cc"]
    run([*cc, "-std=c11", "-O2", "-Wno-incompatible-pointer-types", "-I", generated, "-c", generated / "zova_c.c", "-o", out / "zova.o"], env=env)
    defines = ["SQLITE_THREADSAFE=1", "SQLITE_ENABLE_FTS5", "SQLITE_ENABLE_DBSTAT_VTAB", "SQLITE_ENABLE_RTREE", "SQLITE_ENABLE_GEOPOLY", "SQLITE_ENABLE_CARRAY", "SQLITE_ENABLE_MATH_FUNCTIONS"]
    run([*cc, "-std=c99", "-O2", *["-D" + d for d in defines], "-I", generated, "-c", generated / "sqlite3.c", "-o", out / "sqlite.o"], env=env)
    host = out / ("plugin-smoke.exe" if SYSTEM == "Windows" else "plugin-smoke")
    links = ["-lntdll"] if SYSTEM == "Windows" else ["-lpthread", "-lm"] + (["-ldl"] if SYSTEM == "Linux" else [])
    run([*cc, "-std=c11", "-I", generated, ROOT / "tests/plugin_package_smoke.c", out / "zova.o", out / "sqlite.o", *links, "-o", host], env=env)
    cases = []
    for label, name in (("c", "plugin_recovery_c_fixture"), ("cpp", "plugin_package_cpp")):
        bundle = out / (label + ".zovaext")
        bundle.mkdir()
        library = one_library(out / "fixtures", name)
        shutil.copy2(library, bundle / library.name)
        if label == "cpp":
            dependency = one_library(out / "fixtures", "plugin_package_dependency")
            shutil.copy2(dependency, bundle / dependency.name)
        manifest = {"name": "c_test", "version": "1.0.0", "storage_prefix": "_zova_ext_c_test_", "zova_abi_min": "1.0.0", "capabilities": "", "library": library.name, "entrypoint": "zova_plugin_entry_v1"}
        (bundle / "extension.json").write_text(json.dumps(manifest), encoding="utf-8")
        trust = out / (label + "-trust.json")
        run([host, bundle, out / (label + ".zova"), trust], env=env)
        cases.append((bundle, trust))
        # Changed manifest/dependency bytes invalidate trust before create.
        changed = (bundle / "extension.json").read_bytes()
        (bundle / "extension.json").write_bytes(changed + b"\n")
        run([host, bundle, out / (label + "-changed.zova"), trust, "reject"], env=env)
        assert not (out / (label + "-changed.zova")).exists()
        (bundle / "extension.json").write_bytes(changed)
        if label == "cpp":
            dependency_bytes = (bundle / dependency.name).read_bytes()
            (bundle / dependency.name).write_bytes(dependency_bytes + b"changed")
            run([host, bundle, out / "changed-dependency.zova", trust, "reject"], env=env)
            assert not (out / "changed-dependency.zova").exists()
            (bundle / dependency.name).write_bytes(dependency_bytes)
    incompatible = out / "incompatible.zovaext"
    incompatible.mkdir()
    library = one_library(out / "fixtures", "plugin_package_incompatible")
    shutil.copy2(library, incompatible / library.name)
    manifest["library"] = library.name
    (incompatible / "extension.json").write_text(json.dumps(manifest), encoding="utf-8")
    run([host, incompatible, out / "incompatible.zova", out / "incompatible-trust.json", "incompatible"], env=env)
    assert not (out / "incompatible.zova").exists()
    missing = out / "missing.zovaext"
    shutil.copytree(cases[1][0], missing)
    (missing / dependency.name).unlink()
    # Fresh process: an already mapped dependency cannot conceal a missing file.
    run([host, missing, out / "missing.zova", out / "missing-trust.json", "verify-missing"], env=env)
    assert not (out / "missing.zova").exists()
    (out / "cases.json").write_text(json.dumps([[str(p), str(t)] for p, t in cases]), encoding="utf-8")
    if "GITHUB_ENV" in env:
        with open(env["GITHUB_ENV"], "a", encoding="utf-8") as stream:
            stream.write(f"ZOVA_TEST_PLUGIN_BUNDLE={cases[1][0]}\nZOVA_TEST_PLUGIN_TRUST_STORE={cases[1][1]}\n")
    if args.prepare_only:
        print("Portable package fixtures and generated-C loader checks passed", flush=True)
        return
    print("2/5: Synchronize package sources and test actual generated-C Rust", flush=True)
    run([sys.executable, "scripts/generate-rust-platforms.py", "--host"], env=env)
    run(["sh", "bindings/python/tools/sync-rust-source.sh"], env=env)
    for bundle, trust in cases:
        case_env = {**env, "ZOVA_TEST_PLUGIN_BUNDLE": str(bundle), "ZOVA_TEST_PLUGIN_TRUST_STORE": str(trust)}
        run(["cargo", "nextest", "run", "-p", "zova", "--test", "plugin_loading", "--run-ignored", "all", "--manifest-path", "bindings/rust/Cargo.toml"], env=case_env)
    check_consumers(out, env, cases)


def check_consumers(out, env, cases):
    generated = out / "generated"
    print("3/5: Go against the same generated-C archive", flush=True)
    libdir = out / "lib"
    libdir.mkdir(exist_ok=True)
    archive = libdir / ("zova_c.lib" if SYSTEM == "Windows" else "libzova_c.a")
    run(["zig", "ar", "rcs", archive, out / "zova.o", out / "sqlite.o"], env=env)
    # cgo passes these flags to its generated Go directives too; embedded quote
    # characters around only the path produce invalid cgo_ldflag directives.
    go_env = {**env, "CGO_ENABLED": "1", "CGO_CFLAGS": f'-I{generated.as_posix()}', "CGO_LDFLAGS": f'-L{libdir.as_posix()}'}
    for bundle, trust in cases:
        run(["go", "test", "-count=1", "-run", "TestPluginSelection|TestPortablePluginPackage", "./..."], cwd=ROOT / "bindings/go", env={**go_env, "ZOVA_TEST_PLUGIN_BUNDLE": str(bundle), "ZOVA_TEST_PLUGIN_TRUST_STORE": str(trust)})
    print("4/5: Build/install Python wheel and run consumer tests", flush=True)
    run(["uv", "run", "--isolated", "--with", "maturin", "--directory", "bindings/python", "maturin", "build", "--out", out / "wheels"], env=env)
    wheels = list((out / "wheels").glob("*.whl"))
    if len(wheels) != 1:
        raise RuntimeError("expected one native wheel")
    python = out / "python-env"
    run(["uv", "venv", "--python", "3.14", python], env=env)
    interpreter = python / ("Scripts/python.exe" if SYSTEM == "Windows" else "bin/python")
    run(["uv", "pip", "install", "--python", interpreter, wheels[0], "pytest"], env=env)
    for bundle, trust in cases:
        run([interpreter, "-m", "pytest", ROOT / "bindings/python/tests/test_plugin_loading.py", "-q"], cwd=out, env={**env, "ZOVA_TEST_PLUGIN_BUNDLE": str(bundle), "ZOVA_TEST_PLUGIN_TRUST_STORE": str(trust)})
    print("5/5: Build/install npm tarball and run Node/Bun consumers", flush=True)
    javascript = ROOT / "bindings/javascript"
    run(["bunx", "napi", "build", "--platform", "--target-dir", env["CARGO_TARGET_DIR"]], cwd=javascript, env=env)
    run(["bun", "run", "normalize:package-names"], cwd=javascript, env=env)
    run(["bun", "run", "build:typescript"], cwd=javascript, env=env)
    npm = "npm.cmd" if SYSTEM == "Windows" else "npm"
    consumer = out / "npm-consumer"
    consumer.mkdir()
    (consumer / "package.json").write_text('{"private":true}', encoding="utf-8")
    run([npm, "pack", "--ignore-scripts", "--pack-destination", consumer], cwd=javascript, env=env)
    tarballs = list(consumer.glob("*.tgz"))
    if len(tarballs) != 1:
        raise RuntimeError("expected one npm tarball")
    run([npm, "install", "--ignore-scripts", "--omit=optional", tarballs[0]], cwd=consumer, env=env)
    for bundle, trust in cases:
        case_env = {**env, "ZOVA_TEST_PLUGIN_BUNDLE": str(bundle), "ZOVA_TEST_PLUGIN_TRUST_STORE": str(trust)}
        run(["bun", "test", "tests/plugin-loading.test.ts", "--timeout", "30000"], cwd=javascript, env=case_env)
        for runtime in ("node", "bun"):
            run([runtime, ROOT / "bindings/javascript/tests/plugin-package-consumer.cjs"], cwd=consumer, env=case_env)
    print("All native plugin package checks passed", flush=True)


if __name__ == "__main__":
    main()
