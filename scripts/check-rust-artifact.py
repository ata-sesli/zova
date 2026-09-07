#!/usr/bin/env python3
"""Package once, then exercise immutable crate sources on each native runner."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request

PLATFORMS = {
    "linux-x64": "x86_64-unknown-linux-gnu",
    "linux-arm64": "aarch64-unknown-linux-gnu",
    "darwin-x64": "x86_64-apple-darwin",
    "darwin-arm64": "aarch64-apple-darwin",
    "windows-x64": "x86_64-pc-windows-msvc",
}


def run(*args, **kwargs):
    print("+", " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), check=True, **kwargs)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def publish_metadata(package):
    readme_path = Path(package["readme"]) if package.get("readme") else None
    license_path = Path(package["license_file"]) if package.get("license_file") else None
    dependencies = []
    for dependency in package["dependencies"]:
        dependencies.append({
            "name": dependency["name"],
            "version_req": dependency["req"],
            "features": dependency["features"],
            "optional": dependency["optional"],
            "default_features": dependency["uses_default_features"],
            "target": dependency["target"],
            "kind": dependency["kind"] or "normal",
            "registry": dependency["registry"],
            "explicit_name_in_toml": dependency["rename"],
        })
    return {
        "name": package["name"],
        "vers": package["version"],
        "deps": dependencies,
        "features": package["features"],
        "authors": package["authors"],
        "description": package["description"],
        "documentation": package["documentation"],
        "homepage": package["homepage"],
        "readme": readme_path.read_text() if readme_path else None,
        "readme_file": readme_path.name if readme_path else None,
        "keywords": package["keywords"],
        "categories": package["categories"],
        "license": package["license"],
        "license_file": license_path.name if license_path else None,
        "repository": package["repository"],
        "badges": {},
        "links": package["links"],
        "rust_version": package["rust_version"],
    }


def build_publish_body(metadata, crate):
    encoded_metadata = json.dumps(metadata, separators=(",", ":")).encode()
    if len(encoded_metadata) > 0xFFFFFFFF or len(crate) > 0xFFFFFFFF:
        raise SystemExit("crate publish payload exceeds the registry protocol limit")
    return (
        struct.pack("<I", len(encoded_metadata))
        + encoded_metadata
        + struct.pack("<I", len(crate))
        + crate
    )


def publish(artifact, crate_name):
    manifest = json.loads((artifact / "manifest.json").read_text())
    version = manifest["version"]
    archive = artifact / f"{crate_name}-{version}.crate"
    expected = manifest["sha256"].get(archive.name)
    if expected is None or digest(archive) != expected:
        raise SystemExit(f"artifact hash mismatch: {archive.name}")
    token = os.environ.get("CARGO_REGISTRY_TOKEN")
    if not token:
        raise SystemExit("CARGO_REGISTRY_TOKEN is required")

    with tempfile.TemporaryDirectory(prefix="zova-crate-publish-") as directory:
        root = Path(directory)
        with tarfile.open(archive) as source:
            source.extractall(root, filter="data")
        package_root = root / f"{crate_name}-{version}"
        metadata = json.loads(subprocess.check_output([
            "cargo", "metadata", "--no-deps", "--format-version", "1",
            "--manifest-path", str(package_root / "Cargo.toml"),
        ]))
        package = next(
            item for item in metadata["packages"]
            if item["name"] == crate_name and item["version"] == version
        )
        body = build_publish_body(publish_metadata(package), archive.read_bytes())

    request = urllib.request.Request(
        "https://crates.io/api/v1/crates/new",
        data=body,
        method="PUT",
        headers={
            "Accept": "application/json",
            "Authorization": token,
            "Content-Type": "application/octet-stream",
            "User-Agent": "zova-release-publisher/1",
        },
    )
    try:
        with urllib.request.urlopen(request) as response:
            result = json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise SystemExit(f"crate upload failed ({error.code}): {detail}") from error
    errors = result.get("errors", [])
    if errors:
        raise SystemExit("crate upload failed: " + "; ".join(
            item.get("detail", str(item)) for item in errors
        ))
    print(f"published exact artifact: {archive.name} sha256={expected}", flush=True)


def verify(artifact, work):
    manifest = json.loads((artifact / "manifest.json").read_text())
    if work.exists():
        raise SystemExit(f"verification directory must not exist: {work}")
    work.mkdir(parents=True)
    crates = work / "bindings/rust"
    crates.mkdir(parents=True)
    for name, expected in manifest["sha256"].items():
        archive = artifact / name
        if digest(archive) != expected:
            raise SystemExit(f"artifact hash mismatch: {name}")
        with tarfile.open(archive) as source:
            source.extractall(crates, filter="data")
    version = manifest["version"]
    raw = crates / f"zova-sys-{version}"
    safe = crates / f"zova-{version}"
    if any(p.is_file() and p.name != "LICENSE" for p in (raw / "native").rglob("*")):
        raise SystemExit("dispatcher crate must not contain native sources")
    # Cargo may write locks/build output, but packaged native sources must remain exact.
    native_files = [p for d in crates.glob("zova-sys-*/native") for p in d.rglob("*") if p.is_file()]
    before = {p: digest(p) for p in native_files}
    config = work / "platform-patches.toml"
    config.write_text("[patch.crates-io]\n" + "".join(
        f'{name.removesuffix("-" + version)} = {{ path = {json.dumps(str(crates / name))} }}\n'
        for name in [f"zova-sys-{version}"] + [f"zova-sys-{suffix}-{version}" for suffix in PLATFORMS]))
    for suffix, target in PLATFORMS.items():
        directory = crates / f"zova-sys-{suffix}-{version}" / "native"
        metadata = json.loads((directory / "metadata.json").read_text())
        if metadata["cargo_target"] != target or metadata["zova_version"] != version:
            raise SystemExit(f"incorrect source metadata: {suffix}")
        for name, expected in metadata["sha256"].items():
            if digest(directory / name) != expected:
                raise SystemExit(f"source hash mismatch: {suffix}/{name}")
    env = os.environ.copy()
    for name in ("ZOVA_LIB_DIR", "ZOVA_SOURCE_DIR", "ZOVA_INCLUDE_DIR", "DOCS_RS"):
        env.pop(name, None)
    run("cargo", "nextest", "run", "--manifest-path", raw / "Cargo.toml", "--config", config, env=env)
    run("cargo", "nextest", "run", "--manifest-path", safe / "Cargo.toml", "--config", config, env=env)
    run("cargo", "check", "--examples", "--manifest-path", safe / "Cargo.toml", "--config", config, env=env)
    after = {p: digest(p) for p in native_files}
    if before != after:
        raise SystemExit("packaged native sources changed during verification")
    print("verified immutable Rust artifacts:", manifest["sha256"], flush=True)


def package(root, artifact):
    artifact.mkdir(parents=True, exist_ok=False)
    metadata = json.loads(subprocess.check_output([
        "cargo", "metadata", "--no-deps", "--format-version", "1",
        "--manifest-path", str(root / "bindings/rust/Cargo.toml")]))
    version = next(p["version"] for p in metadata["packages"] if p["name"] == "zova-sys")
    run("cargo", "package", "--allow-dirty", "--no-verify", "--workspace",
        "--manifest-path", root / "bindings/rust/Cargo.toml")
    for crate in [f"zova-sys-{suffix}" for suffix in PLATFORMS] + ["zova-sys", "zova"]:
        name = f"{crate}-{version}.crate"
        shutil.copy2(Path(metadata["target_directory"]) / "package" / name, artifact / name)
        if (artifact / name).stat().st_size >= 10 * 1024 * 1024:
            raise SystemExit(f"crate exceeds 10 MiB: {name}")
    manifest = {"version": version, "sha256": {p.name: digest(p) for p in artifact.glob("*.crate")}}
    (artifact / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    shutil.copy2(__file__, artifact / "check-rust-artifact.py")
    print(json.dumps(manifest, indent=2), flush=True)


def overrides(artifact, work, source):
    version = json.loads((artifact / "manifest.json").read_text())["version"]
    raw = work / "bindings/rust" / f"zova-sys-{version}"
    config = work / "platform-patches.toml"
    env = os.environ.copy()
    for name in ("ZOVA_LIB_DIR", "ZOVA_SOURCE_DIR", "ZOVA_INCLUDE_DIR", "DOCS_RS"):
        env.pop(name, None)
    command = ["cargo", "build", "--manifest-path", str(raw / "Cargo.toml"), "--config", str(config), "--message-format=json"]
    metadata = json.loads(subprocess.check_output(["cargo", "metadata", "--manifest-path", str(raw / "Cargo.toml"), "--config", str(config), "--format-version=1"], env=env))
    package_id = next(p["id"] for p in metadata["packages"] if p["name"] == "zova-sys")
    events = [json.loads(line) for line in subprocess.check_output(command, env=env, text=True).splitlines()]
    lib_dir = next(e["out_dir"] for e in events if e["reason"] == "build-script-executed" and e["package_id"] == package_id)
    print(f"Testing ZOVA_LIB_DIR={lib_dir}", flush=True)
    run("cargo", "nextest", "run", "--manifest-path", raw / "Cargo.toml", "--config", config, env={**env, "ZOVA_LIB_DIR": lib_dir})
    print(f"Testing ZOVA_SOURCE_DIR={source}", flush=True)
    run("cargo", "nextest", "run", "--manifest-path", raw / "Cargo.toml", "--config", config, env={**env, "ZOVA_SOURCE_DIR": str(source)})
    # Revalidate every immutable source after override tests, too.
    for directory in (work / "bindings/rust").glob("zova-sys-*/native"):
        if not (directory / "metadata.json").exists():
            continue
        for name, expected in json.loads((directory / "metadata.json").read_text())["sha256"].items():
            if digest(directory / name) != expected:
                raise SystemExit(f"override modified packaged source: {directory / name}")


if __name__ == "__main__":
    if len(sys.argv) < 4:
        raise SystemExit(
            "expected package ROOT OUTPUT, verify ARTIFACT WORK, "
            "overrides ARTIFACT WORK SOURCE, or publish ARTIFACT CRATE"
        )
    mode, first, second = sys.argv[1:4]
    if mode == "package":
        package(Path(first).resolve(), Path(second).resolve())
    elif mode == "verify":
        verify(Path(first).resolve(), Path(second).resolve())
    elif mode == "overrides":
        overrides(Path(first).resolve(), Path(second).resolve(), Path(sys.argv[4]).resolve())
    elif mode == "publish":
        publish(Path(first).resolve(), second)
    else:
        raise SystemExit("unknown mode")
