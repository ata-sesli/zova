use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    napi_build::setup();

    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let version_path = manifest_dir.join("../../src/version.zig");
    println!("cargo:rerun-if-changed={}", version_path.display());

    let version_source =
        fs::read_to_string(&version_path).expect("read Zova's central version module");
    for name in ["format_version", "sqlite_version"] {
        let value = zig_string_constant(&version_source, name)
            .unwrap_or_else(|| panic!("read {name} from {}", version_path.display()));
        println!("cargo:rustc-env=ZOVA_{}={value}", name.to_ascii_uppercase());
    }
}

fn zig_string_constant<'a>(source: &'a str, name: &str) -> Option<&'a str> {
    let prefix = format!("pub const {name} = \"");
    source
        .lines()
        .find_map(|line| line.trim().strip_prefix(&prefix))
        .and_then(|rest| rest.strip_suffix("\";"))
}

#[cfg(test)]
mod tests {
    use super::zig_string_constant;

    #[test]
    fn reads_zig_string_constants() {
        let source = "pub const format_version = \"10\";\n";
        assert_eq!(zig_string_constant(source, "format_version"), Some("10"));
        assert_eq!(zig_string_constant(source, "missing"), None);
    }
}
