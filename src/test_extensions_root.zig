test "extension test suite" {
    _ = @import("extension.zig");
    _ = @import("extension_dynamic.zig");
    _ = @import("trgm_tests.zig");
}
