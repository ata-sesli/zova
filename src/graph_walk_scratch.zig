//! Connection-owned scratch storage for bounded graph walks.
//!
//! The scratch allocator is deliberately separate from the caller allocator:
//! only visited/frontier backing storage uses it. GraphWalkItem strings and the
//! returned result array remain caller-owned, so a later walk can never change
//! or free a result returned by an earlier walk.

const std = @import("std");

/// Maximum capacity retained by one connection after a walk completes.
pub const retained_capacity_limit: usize = 1 * 1024 * 1024;

pub const GraphWalkScratch = struct {
    arena: std.heap.ArenaAllocator,
    in_use: bool = false,

    pub fn init() GraphWalkScratch {
        return .{ .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator) };
    }

    /// Acquire the exclusive connection-owned scratch lease. External
    /// serialization protects normal calls; `false` is for nested/reentrant
    /// calls, which must use an independent temporary arena instead.
    pub fn acquire(self: *GraphWalkScratch) bool {
        if (self.in_use) return false;
        self.in_use = true;
        return true;
    }

    pub fn allocator(self: *GraphWalkScratch) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Clear all logical allocations while retaining at most one MiB of arena
    /// capacity. Oversize work is returned to c_allocator here.
    pub fn release(self: *GraphWalkScratch) void {
        std.debug.assert(self.in_use);
        _ = self.arena.reset(.{ .retain_with_limit = retained_capacity_limit });
        self.in_use = false;
    }

    pub fn retainedCapacity(self: *const GraphWalkScratch) usize {
        return self.arena.queryCapacity();
    }

    pub fn deinit(self: *GraphWalkScratch) void {
        self.arena.deinit();
        self.in_use = false;
    }
};
