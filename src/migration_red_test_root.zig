//! Test root for the opt-in RED storage-format classification suite.
//!
//! Run with `zig build migration-red-test`. These tests define the target
//! contract for format probing and precise open errors and are expected to
//! fail until the migration open path lands.

test {
    _ = @import("migration_red_tests.zig");
}
