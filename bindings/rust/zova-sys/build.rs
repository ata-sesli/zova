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
    }
}

fn build_local_zova() -> PathBuf {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));

    if let Ok(path) = env::var("ZOVA_SOURCE_DIR") {
        return build_zig_source(&PathBuf::from(path));
    }

    let generated = manifest_dir.join("native/generated");
    if generated.join("zova_c.c").exists() {
        return build_generated_c(&generated);
    }

    let source_root = source_root_for_build(&manifest_dir);
    build_zig_source(&source_root)
}

fn build_generated_c(generated_dir: &Path) -> PathBuf {
    for name in [
        "zova_c.c",
        "zig.h",
        "zova.h",
        "sqlite3.c",
        "sqlite3.h",
        "sqlite3ext.h",
    ] {
        let path = generated_dir.join(name);
        if !path.exists() {
            panic!(
                "generated Zova C bundle is missing {}; run bindings/rust/zova-sys/tools/sync-native-source.sh",
                path.display()
            );
        }
        println!("cargo:rerun-if-changed={}", path.display());
    }

    if env::var_os("ZOVA_INCLUDE_DIR").is_none() {
        println!("cargo:include={}", generated_dir.display());
    }

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let lib_dir = absolute_dir(&out_dir.join("zova-c-abi/lib"));
    let obj_dir = absolute_dir(&out_dir.join("zova-c-abi/obj"));
    let zova_obj = obj_dir.join("zova_c.o");
    let sqlite_obj = obj_dir.join("sqlite3.o");

    compile_c_object(
        generated_dir,
        &generated_dir.join("zova_c.c"),
        &zova_obj,
        "c11",
        &["-O2", "-Wno-incompatible-pointer-types"],
    );
    compile_c_object(
        generated_dir,
        &generated_dir.join("sqlite3.c"),
        &sqlite_obj,
        "c99",
        &[
            "-O2",
            "-fno-sanitize=undefined",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_ENABLE_DBSTAT_VTAB",
        ],
    );

    archive_static_library(&lib_dir, &[zova_obj, sqlite_obj]);
    assert_static_library_exists(&lib_dir);
    lib_dir
}

fn compile_c_object(
    include_dir: &Path,
    source: &Path,
    output: &Path,
    standard: &str,
    default_flags: &[&str],
) {
    let compiler = env::var("CC").unwrap_or_else(|_| "cc".to_string());
    let mut command = Command::new(&compiler);
    command
        .arg(format!("-std={standard}"))
        .arg("-I")
        .arg(include_dir);
    if env::var("CARGO_CFG_TARGET_FAMILY").as_deref() == Ok("unix") {
        command.arg("-fPIC");
    }
    for flag in default_flags {
        command.arg(flag);
    }
    if let Ok(flags) = env::var("CFLAGS") {
        for flag in flags.split_whitespace() {
            command.arg(flag);
        }
    }
    command.arg("-c").arg(source).arg("-o").arg(output);

    let status = command.status().unwrap_or_else(|err| {
        panic!(
            "failed to run C compiler `{compiler}` for {}: {err}",
            source.display()
        )
    });
    if !status.success() {
        panic!(
            "C compiler `{compiler}` failed while compiling {} with status {status}",
            source.display()
        );
    }
}

fn archive_static_library(lib_dir: &Path, objects: &[PathBuf]) {
    if env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc") {
        let archive = lib_dir.join("zova_c.lib");
        let mut command = Command::new("lib");
        command.arg(format!("/OUT:{}", archive.display()));
        command.args(objects);
        let status = command
            .status()
            .expect("failed to run `lib` while archiving generated Zova C objects");
        if !status.success() {
            panic!("`lib` failed while archiving generated Zova C objects with status {status}");
        }
        return;
    }

    let archive = lib_dir.join("libzova_c.a");
    let archiver = env::var("AR").unwrap_or_else(|_| "ar".to_string());
    let mut command = Command::new(&archiver);
    command.arg("crs").arg(&archive).args(objects);
    let status = command
        .status()
        .unwrap_or_else(|err| panic!("failed to run archiver `{archiver}`: {err}"));
    if !status.success() {
        panic!("archiver `{archiver}` failed with status {status}");
    }
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
    let status = Command::new("zig")
        .arg("build")
        .arg("c-abi")
        .arg("-Doptimize=ReleaseFast")
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

fn source_root_for_build(manifest_dir: &Path) -> PathBuf {
    if let Some(repo_root) = find_repository_root(manifest_dir) {
        return repo_root;
    }

    let bundled = manifest_dir.join("native");
    if bundled.join("build.zig").exists() {
        return bundled;
    }

    panic!(
        "unable to find Zova source from {}; set ZOVA_LIB_DIR or ZOVA_SOURCE_DIR",
        manifest_dir.display()
    );
}

fn find_repository_root(manifest_dir: &Path) -> Option<PathBuf> {
    let repo_root = manifest_dir.ancestors().nth(3)?;
    if repo_root.join("build.zig").exists()
        && repo_root.join("include/zova.h").exists()
        && repo_root.join("src/c_api.zig").exists()
    {
        Some(repo_root.to_path_buf())
    } else {
        None
    }
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
