test "object_tests suite" {
    _ = @import("object_tests.zig");
}

test "object_sha256 suite" {
    _ = @import("object_sha256.zig");
}

test "object_lz4 suite" {
    _ = @import("object_lz4.zig");
}
