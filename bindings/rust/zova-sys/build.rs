use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=ZOVA_LIB_DIR");
    println!("cargo:rerun-if-env-changed=ZOVA_INCLUDE_DIR");

    if let Ok(include_dir) = env::var("ZOVA_INCLUDE_DIR") {
        println!("cargo:include={include_dir}");
    }

    let lib_dir = match env::var("ZOVA_LIB_DIR") {
        Ok(path) => PathBuf::from(path),
        Err(_) => build_local_zova(),
    };

    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=static=zova_c");

    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        println!("cargo:rustc-link-lib=dylib=pthread");
        println!("cargo:rustc-link-lib=dylib=dl");
        println!("cargo:rustc-link-lib=dylib=m");
    }
}

fn build_local_zova() -> PathBuf {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let repo_root = manifest_dir
        .ancestors()
        .nth(3)
        .expect("zova-sys must live under bindings/rust/zova-sys")
        .to_path_buf();

    let build_zig = repo_root.join("build.zig");
    if !build_zig.exists() {
        panic!(
            "unable to find Zova repository root at {}; set ZOVA_LIB_DIR instead",
            repo_root.display()
        );
    }

    println!(
        "cargo:rerun-if-changed={}",
        repo_root.join("include/zova.h").display()
    );
    println!("cargo:rerun-if-changed={}", repo_root.join("src").display());
    println!("cargo:rerun-if-changed={}", build_zig.display());

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let prefix = out_dir.join("zova-c-abi");
    let status = Command::new("zig")
        .arg("build")
        .arg("c-abi")
        .arg("-Doptimize=ReleaseFast")
        .arg("-p")
        .arg(&prefix)
        .current_dir(&repo_root)
        .status()
        .expect("failed to run `zig build c-abi`");

    if !status.success() {
        panic!("`zig build c-abi` failed with status {status}");
    }

    let lib_dir = prefix.join("lib");
    assert_static_library_exists(&lib_dir);
    lib_dir
}

fn assert_static_library_exists(lib_dir: &Path) {
    let names = ["libzova_c.a", "zova_c.lib"];
    if names.iter().any(|name| lib_dir.join(name).exists()) {
        return;
    }

    panic!(
        "Zova static library was not installed under {}; expected one of {:?}",
        lib_dir.display(),
        names
    );
}
