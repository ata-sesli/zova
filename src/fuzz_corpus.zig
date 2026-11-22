//! Encoders for `std.testing.fuzz` corpus entries.
//!
//! Without `--fuzz`, the test runner replays each corpus entry through
//! `std.testing.Smith`, which reads an integer as 8 little-endian bytes and a
//! slice as a little-endian u32 length followed by the bytes. Call these at
//! comptime and concatenate them in the order the fuzz function reads values.

const std = @import("std");

pub fn slice(comptime bytes: []const u8) []const u8 {
    return &std.mem.toBytes(std.mem.nativeToLittle(u32, bytes.len)) ++ bytes;
}

pub fn int(comptime value: u64) []const u8 {
    return &std.mem.toBytes(std.mem.nativeToLittle(u64, value));
}
