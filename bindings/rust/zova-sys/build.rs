mod build_target;

use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=ZOVA_LIB_DIR");
    println!("cargo:rerun-if-env-changed=ZOVA_INCLUDE_DIR");
    println!("cargo:rerun-if-env-changed=ZOVA_SOURCE_DIR");
    println!("cargo:rerun-if-env-changed=CC");
    println!("cargo:rerun-if-env-changed=CFLAGS");
    println!("cargo:rerun-if-env-changed=AR");
    println!("cargo:rerun-if-env-changed=DOCS_RS");

    if env::var_os("DOCS_RS").is_some() {
        println!("cargo:warning=skipping native Zova build while generating docs.rs documentation");
        return;
    }

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
    } else if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        println!("cargo:rustc-link-lib=dylib=ntdll");
    }
}

fn build_local_zova() -> PathBuf {
    if let Ok(path) = env::var("ZOVA_SOURCE_DIR") {
        return build_zig_source(&PathBuf::from(path));
    }

    let target = env::var("TARGET").expect("Cargo TARGET is required");
    let key = build_target::metadata_key(&target).unwrap_or_else(|| {
        panic!("unsupported Zova target: {target}; provide ZOVA_LIB_DIR or ZOVA_SOURCE_DIR");
    });
    let source = env::var_os(key)
        .unwrap_or_else(|| panic!("missing platform source metadata {key} for {target}"));
    build_generated_c(&PathBuf::from(source), &target)
}

fn build_generated_c(source: &Path, target: &str) -> PathBuf {
    let recorded_target = std::fs::read_to_string(source.join("cargo-target.txt"))
        .expect("missing platform target metadata; regenerate the platform source package");
    assert_eq!(
        recorded_target.trim(),
        target,
        "Zova platform source target mismatch"
    );
    let version = std::fs::read_to_string(source.join("version.txt"))
        .expect("missing platform version metadata");
    assert_eq!(
        version.trim(),
        env!("CARGO_PKG_VERSION"),
        "Zova platform source version mismatch"
    );
    for file in [
        "zova_c.c",
        "sqlite3.c",
        "zig.h",
        "zova.h",
        "sqlite3.h",
        "sqlite3ext.h",
        "metadata.json",
        "cargo-target.txt",
        "version.txt",
    ] {
        let path = source.join(file);
        assert!(
            path.is_file(),
            "missing generated source: {}",
            path.display()
        );
        println!("cargo:rerun-if-changed={}", path.display());
    }
    if env::var_os("ZOVA_INCLUDE_DIR").is_none() {
        println!("cargo:include={}", source.display());
    }
    let mut build = cc::Build::new();
    build
        .target(target)
        .include(source)
        .file(source.join("zova_c.c"))
        .file(source.join("sqlite3.c"))
        .opt_level(2)
        .warnings(false)
        .define("SQLITE_THREADSAFE", "1")
        .define("SQLITE_ENABLE_FTS5", None)
        .define("SQLITE_ENABLE_DBSTAT_VTAB", None)
        .define("SQLITE_ENABLE_RTREE", None)
        .define("SQLITE_ENABLE_GEOPOLY", None)
        .define("SQLITE_ENABLE_CARRAY", None)
        .define("SQLITE_ENABLE_MATH_FUNCTIONS", None)
        .cargo_metadata(false);
    // Zig's C backend uses Clang extensions. cc handles target-specific
    // CC/CFLAGS/AR overrides and platform archive/linker conventions.
    if build
        .try_get_compiler()
        .map_or(true, |c| !c.is_like_clang())
    {
        // Explicit compiler overrides remain authoritative.
        let specific = format!("CC_{}", target.replace('-', "_"));
        let literal = format!("CC_{target}");
        if env::var_os("CC").is_none()
            && env::var_os(&specific).is_none()
            && env::var_os(&literal).is_none()
            && env::var_os("TARGET_CC").is_none()
        {
            build.compiler(if target.ends_with("msvc") {
                "clang-cl"
            } else {
                "clang"
            });
        }
    }
    build
        .flag_if_supported("-Wno-incompatible-pointer-types")
        .flag_if_supported("-fno-sanitize=undefined")
        .compile("zova_c");
    PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR"))
}

fn build_zig_source(source_root: &Path) -> PathBuf {
    let build_zig = source_root.join("build.zig");
    if !build_zig.exists() {
        panic!(
            "unable to find Zova build.zig at {}; set ZOVA_LIB_DIR or ZOVA_SOURCE_DIR instead",
            build_zig.display()
        );
    }

    let include_dir = source_root.join("include");
    if env::var_os("ZOVA_INCLUDE_DIR").is_none() && include_dir.join("zova.h").exists() {
        println!("cargo:include={}", include_dir.display());
    }

    println!(
        "cargo:rerun-if-changed={}",
        source_root.join("include/zova.h").display()
    );
    println!("cargo:rerun-if-changed={}", build_zig.display());
    println!(
        "cargo:rerun-if-changed={}",
        source_root.join("build.zig.zon").display()
    );
    emit_rerun_if_changed_recursive(&source_root.join("src"));
    emit_rerun_if_changed_recursive(&source_root.join("vendor"));
    emit_rerun_if_changed_recursive(&source_root.join("tests"));

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let prefix = out_dir.join("zova-c-abi");
    let cache_dir = absolute_dir(&out_dir.join("zig-cache"));
    let global_cache_dir = absolute_dir(&out_dir.join("zig-global-cache"));
    let mut command = Command::new("zig");
    command
        .arg("build")
        .arg("c-abi")
        .arg("-Doptimize=ReleaseFast");
    let target = env::var("TARGET").expect("Cargo TARGET is required");
    let zig_target = build_target::zig_target(&target).unwrap_or_else(|| {
        panic!("unsupported Zova automatic-build target: {target}; provide ZOVA_LIB_DIR and ZOVA_INCLUDE_DIR for a custom native build");
    });
    command.arg(format!("-Dtarget={zig_target}"));
    // Match the packaged generated-C feature set, while preserving the explicit
    // source override's existing build defaults.
    if env::var_os("ZOVA_SOURCE_DIR").is_none() {
        command.arg("-Denable-dynamic-extensions=false");
    }
    let status = command
        .arg("--cache-dir")
        .arg(&cache_dir)
        .arg("--global-cache-dir")
        .arg(&global_cache_dir)
        .arg("-p")
        .arg(&prefix)
        .current_dir(&source_root)
        .status()
        .expect("failed to run `zig build c-abi`");

    if !status.success() {
        panic!("`zig build c-abi` failed with status {status}");
    }

    let lib_dir = prefix.join("lib");
    assert_static_library_exists(&lib_dir);
    repack_macos_static_library(&lib_dir);
    lib_dir
}

fn absolute_dir(path: &Path) -> PathBuf {
    std::fs::create_dir_all(path)
        .unwrap_or_else(|err| panic!("failed to create {}: {err}", path.display()));
    path.canonicalize()
        .unwrap_or_else(|err| panic!("failed to canonicalize {}: {err}", path.display()))
}

fn emit_rerun_if_changed_recursive(path: &Path) {
    if !path.exists() {
        return;
    }

    let entries = std::fs::read_dir(path)
        .unwrap_or_else(|err| panic!("failed to read {}: {err}", path.display()));
    for entry in entries {
        let entry = entry.unwrap_or_else(|err| {
            panic!(
                "failed to read directory entry under {}: {err}",
                path.display()
            )
        });
        let entry_path = entry.path();
        let file_type = entry.file_type().unwrap_or_else(|err| {
            panic!(
                "failed to read file type for {}: {err}",
                entry_path.display()
            )
        });
        if file_type.is_dir() {
            emit_rerun_if_changed_recursive(&entry_path);
        } else {
            println!("cargo:rerun-if-changed={}", entry_path.display());
        }
    }
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

fn repack_macos_static_library(lib_dir: &Path) {
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }

    let archive = lib_dir.join("libzova_c.a");
    if !archive.exists() {
        return;
    }

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let repack_dir = out_dir.join("darwin-repack");
    if repack_dir.exists() {
        std::fs::remove_dir_all(&repack_dir).unwrap_or_else(|err| {
            panic!(
                "failed to remove stale Darwin archive repack directory {}: {err}",
                repack_dir.display()
            )
        });
    }
    std::fs::create_dir_all(&repack_dir).unwrap_or_else(|err| {
        panic!(
            "failed to create Darwin archive repack directory {}: {err}",
            repack_dir.display()
        )
    });

    let original = repack_dir.join("original.a");
    std::fs::copy(&archive, &original).unwrap_or_else(|err| {
        panic!(
            "failed to copy {} to {} for Darwin archive repack: {err}",
            archive.display(),
            original.display()
        )
    });

    let members_output = Command::new("ar")
        .arg("-t")
        .arg("original.a")
        .current_dir(&repack_dir)
        .output()
        .expect("failed to run `ar -t` while repacking Darwin archive");
    if !members_output.status.success() {
        panic!(
            "`ar -t` failed while repacking Darwin archive with status {}",
            members_output.status
        );
    }

    let members_text = String::from_utf8(members_output.stdout)
        .expect("Darwin archive member list was not valid UTF-8");
    let members: Vec<&str> = members_text
        .lines()
        .filter(|line| line.ends_with(".o"))
        .collect();
    if members.is_empty() {
        panic!(
            "Darwin archive {} contains no object members to repack",
            archive.display()
        );
    }

    let extract_status = Command::new("ar")
        .arg("-x")
        .arg("original.a")
        .current_dir(&repack_dir)
        .status()
        .expect("failed to run `ar -x` while repacking Darwin archive");
    if !extract_status.success() {
        panic!("`ar -x` failed while repacking Darwin archive with status {extract_status}");
    }

    for member in &members {
        make_repacked_member_readable(&repack_dir.join(member));
    }

    let mut libtool = Command::new("libtool");
    libtool
        .arg("-static")
        .arg("-o")
        .arg("libzova_c.a")
        .args(&members)
        .current_dir(&repack_dir);
    let libtool_status = libtool
        .status()
        .expect("failed to run `libtool -static` while repacking Darwin archive");
    if !libtool_status.success() {
        panic!(
            "`libtool -static` failed while repacking Darwin archive with status {libtool_status}"
        );
    }

    let ranlib_status = Command::new("ranlib")
        .arg("libzova_c.a")
        .current_dir(&repack_dir)
        .status()
        .expect("failed to run `ranlib` while repacking Darwin archive");
    if !ranlib_status.success() {
        panic!("`ranlib` failed while repacking Darwin archive with status {ranlib_status}");
    }

    std::fs::copy(repack_dir.join("libzova_c.a"), &archive).unwrap_or_else(|err| {
        panic!(
            "failed to replace {} with Darwin-repacked archive: {err}",
            archive.display()
        )
    });
}

#[cfg(unix)]
fn make_repacked_member_readable(path: &Path) {
    use std::os::unix::fs::PermissionsExt;

    let mut permissions = std::fs::metadata(path)
        .unwrap_or_else(|err| panic!("failed to stat {}: {err}", path.display()))
        .permissions();
    permissions.set_mode(0o644);
    std::fs::set_permissions(path, permissions)
        .unwrap_or_else(|err| panic!("failed to chmod {}: {err}", path.display()));
}

#[cfg(not(unix))]
fn make_repacked_member_readable(_path: &Path) {}
