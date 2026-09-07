fn main() {
    let source = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("native");
    println!("cargo::metadata=source={}", source.display());
    println!("cargo:rerun-if-changed=native");
}
