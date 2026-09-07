#[path = "../build_target.rs"]
mod build_target;

#[test]
fn maps_all_release_targets_explicitly() {
    for (cargo, zig) in [
        ("x86_64-unknown-linux-gnu", "x86_64-linux-gnu"),
        ("aarch64-unknown-linux-gnu", "aarch64-linux-gnu"),
        ("x86_64-apple-darwin", "x86_64-macos"),
        ("aarch64-apple-darwin", "aarch64-macos"),
        ("x86_64-pc-windows-msvc", "x86_64-windows-msvc"),
    ] {
        assert_eq!(build_target::zig_target(cargo), Some(zig));
    }
}

#[test]
fn unsupported_targets_never_fall_back_to_host() {
    for target in [
        "wasm32-unknown-unknown",
        "x86_64-unknown-linux-musl",
        "",
        "aarch64-pc-windows-msvc",
    ] {
        assert_eq!(build_target::zig_target(target), None);
    }
}

#[test]
fn platform_metadata_is_selected_by_consumer_target() {
    assert_eq!(
        build_target::metadata_key("aarch64-apple-darwin"),
        Some("DEP_ZOVA_SOURCE_DARWIN_ARM64_SOURCE")
    );
    assert_eq!(
        build_target::metadata_key("x86_64-unknown-linux-gnu"),
        Some("DEP_ZOVA_SOURCE_LINUX_X64_SOURCE")
    );
    assert_eq!(
        build_target::metadata_key("x86_64-pc-windows-msvc"),
        Some("DEP_ZOVA_SOURCE_WINDOWS_X64_SOURCE")
    );
    assert_eq!(build_target::metadata_key("wasm32-unknown-unknown"), None);
}
