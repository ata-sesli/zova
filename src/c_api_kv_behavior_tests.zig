//! Public-only C ABI behavior tests. No private implementation helpers.

const std = @import("std");
const zova_database = @import("c_api_internal.zig").zova_database;
const zova_database_close = @import("c_api_internal.zig").zova_database_close;
const zova_database_create = @import("c_api_internal.zig").zova_database_create;
const zova_kv_bytes = @import("c_api_internal.zig").zova_kv_bytes;
const zova_kv_clear_namespace = @import("c_api_internal.zig").zova_kv_clear_namespace;
const zova_kv_count = @import("c_api_internal.zig").zova_kv_count;
const zova_kv_delete = @import("c_api_internal.zig").zova_kv_delete;
const zova_kv_delete_many = @import("c_api_internal.zig").zova_kv_delete_many;
const zova_kv_get = @import("c_api_internal.zig").zova_kv_get;
const zova_kv_get_many = @import("c_api_internal.zig").zova_kv_get_many;
const zova_kv_get_many_results = @import("c_api_internal.zig").zova_kv_get_many_results;
const zova_kv_get_many_results_free = @import("c_api_internal.zig").zova_kv_get_many_results_free;
const zova_kv_get_result = @import("c_api_internal.zig").zova_kv_get_result;
const zova_kv_get_result_free = @import("c_api_internal.zig").zova_kv_get_result_free;
const zova_kv_put = @import("c_api_internal.zig").zova_kv_put;
const zova_kv_put_entry = @import("c_api_internal.zig").zova_kv_put_entry;
const zova_kv_put_many = @import("c_api_internal.zig").zova_kv_put_many;
const zova_status = @import("c_api_internal.zig").zova_status;

test "c abi exposes transactional key-value operations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-kv.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.OK, zova_kv_put(&.{
        .db = db,
        .ns = .{ .data = "settings", .len = 8 },
        .key = .{ .data = "theme", .len = 5 },
        .value = .{ .data = "dark", .len = 4 },
    }));

    var result = zova_kv_get_result{ .found = 0, .value = .{ .data = null, .len = 0 } };
    try std.testing.expectEqual(zova_status.OK, zova_kv_get(&.{
        .db = db,
        .ns = .{ .data = "settings", .len = 8 },
        .key = .{ .data = "theme", .len = 5 },
        .out_result = &result,
    }));
    try std.testing.expectEqual(@as(u8, 1), result.found);
    try std.testing.expectEqualSlices(u8, "dark", result.value.data.?[0..result.value.len]);
    zova_kv_get_result_free(&result);
    try std.testing.expectEqual(@as(u8, 0), result.found);

    var missing = zova_kv_get_result{ .found = 0, .value = .{ .data = null, .len = 0 } };
    try std.testing.expectEqual(zova_status.OK, zova_kv_get(&.{
        .db = db,
        .ns = .{ .data = "settings", .len = 8 },
        .key = .{ .data = "nope", .len = 4 },
        .out_result = &missing,
    }));
    try std.testing.expectEqual(@as(u8, 0), missing.found);
    try std.testing.expectEqual(@as(usize, 0), missing.value.len);
    zova_kv_get_result_free(&missing);

    const keys = [_]zova_kv_bytes{
        .{ .data = "theme", .len = 5 },
        .{ .data = "theme", .len = 5 },
        .{ .data = "nope", .len = 4 },
    };
    var many = zova_kv_get_many_results{ .items = null, .len = 0 };
    try std.testing.expectEqual(zova_status.OK, zova_kv_get_many(&.{
        .db = db,
        .ns = .{ .data = "settings", .len = 8 },
        .keys = &keys,
        .keys_len = keys.len,
        .out_results = &many,
    }));
    try std.testing.expectEqual(@as(usize, 3), many.len);
    try std.testing.expectEqual(@as(u8, 1), many.items.?[0].found);
    try std.testing.expectEqual(@as(u8, 1), many.items.?[1].found);
    try std.testing.expectEqual(@as(u8, 0), many.items.?[2].found);
    try std.testing.expectEqualSlices(u8, "dark", many.items.?[0].value.data.?[0..many.items.?[0].value.len]);
    zova_kv_get_many_results_free(&many);
    try std.testing.expectEqual(@as(usize, 0), many.len);

    var count: u64 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_kv_count(&.{
        .db = db,
        .ns = .{ .data = "settings", .len = 8 },
        .out_count = &count,
    }));
    try std.testing.expectEqual(@as(u64, 1), count);

    const batch_entries = [_]zova_kv_put_entry{
        .{ .key = .{ .data = "retries", .len = 7 }, .value = .{ .data = "\x00\x01\x02", .len = 3 } },
        .{ .key = .{ .data = "theme", .len = 5 }, .value = .{ .data = "light", .len = 5 } },
    };
    try std.testing.expectEqual(zova_status.OK, zova_kv_put_many(&.{
        .db = db,
        .ns = .{ .data = "settings", .len = 8 },
        .entries = &batch_entries,
        .entries_len = batch_entries.len,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_kv_count(&.{
        .db = db,
        .ns = .{ .data = "settings", .len = 8 },
        .out_count = &count,
    }));
    try std.testing.expectEqual(@as(u64, 2), count);

    try std.testing.expectEqual(zova_status.OK, zova_kv_put_many(&.{
        .db = db,
        .ns = .{ .data = "settings", .len = 8 },
        .entries = null,
        .entries_len = 0,
    }));

    const del_keys = [_]zova_kv_bytes{
        .{ .data = "theme", .len = 5 },
        .{ .data = "ghost", .len = 5 },
    };
    try std.testing.expectEqual(zova_status.OK, zova_kv_delete_many(&.{
        .db = db,
        .ns = .{ .data = "settings", .len = 8 },
        .keys = &del_keys,
        .keys_len = del_keys.len,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_kv_count(&.{
        .db = db,
        .ns = .{ .data = "settings", .len = 8 },
        .out_count = &count,
    }));
    try std.testing.expectEqual(@as(u64, 1), count);

    try std.testing.expectEqual(zova_status.OK, zova_kv_clear_namespace(&.{
        .db = db,
        .ns = .{ .data = "settings", .len = 8 },
    }));
    try std.testing.expectEqual(zova_status.OK, zova_kv_count(&.{
        .db = db,
        .ns = .{ .data = "settings", .len = 8 },
        .out_count = &count,
    }));
    try std.testing.expectEqual(@as(u64, 0), count);

    try std.testing.expectEqual(zova_status.OK, zova_kv_delete(&.{
        .db = db,
        .ns = .{ .data = "settings", .len = 8 },
        .key = .{ .data = "theme", .len = 5 },
    }));

    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_kv_put(&.{
        .db = db,
        .ns = .{ .data = null, .len = 8 },
        .key = .{ .data = "theme", .len = 5 },
        .value = .{ .data = "dark", .len = 4 },
    }));
}
