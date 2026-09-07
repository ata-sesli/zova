// Explicit release target mapping: generated/native code must never use HOST.
pub fn zig_target(target: &str) -> Option<&'static str> {
    match target {
        "x86_64-unknown-linux-gnu" => Some("x86_64-linux-gnu"),
        "aarch64-unknown-linux-gnu" => Some("aarch64-linux-gnu"),
        "x86_64-apple-darwin" => Some("x86_64-macos"),
        "aarch64-apple-darwin" => Some("aarch64-macos"),
        "x86_64-pc-windows-msvc" => Some("x86_64-windows-msvc"),
        _ => None,
    }
}

pub fn metadata_key(target: &str) -> Option<&'static str> {
    match target {
        "x86_64-unknown-linux-gnu" => Some("DEP_ZOVA_SOURCE_LINUX_X64_SOURCE"),
        "aarch64-unknown-linux-gnu" => Some("DEP_ZOVA_SOURCE_LINUX_ARM64_SOURCE"),
        "x86_64-apple-darwin" => Some("DEP_ZOVA_SOURCE_DARWIN_X64_SOURCE"),
        "aarch64-apple-darwin" => Some("DEP_ZOVA_SOURCE_DARWIN_ARM64_SOURCE"),
        "x86_64-pc-windows-msvc" => Some("DEP_ZOVA_SOURCE_WINDOWS_X64_SOURCE"),
        _ => None,
    }
}
