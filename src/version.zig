//! Central Zova version constants.
//!
//! Package managers still require their own metadata files, but compiled Zova
//! code should read release, ABI, storage-format, and dependency version values
//! from this module instead of hardcoding them locally.

pub const package_version = "0.22.0";

pub const abi_version_major: u32 = 0;
pub const abi_version_minor: u32 = 22;
pub const abi_version_patch: u32 = 0;
pub const abi_version_string = "0.22.0";

pub const format_version = "6";
pub const sqlite_version = "3.53.2";
pub const minimum_zig_version = "0.16.0";
