//! CWAL prototype: coordinated WAL publication and recovery across a small,
//! fixed set of SQLite files (a main database plus attached stores).
//!
//! The VFS wraps SQLite's "unix" VFS. It adds:
//! - fault injection: a global event counter over every write, sync,
//!   truncate, lock and protocol step, with a crash (SIGKILL) at a chosen
//!   event and an optional power-loss model that loses or tears unsynced
//!   writes;
//! - the coordination protocol, enabled per connection (`Mode.cwal`):
//!   a seqlock publication window with snapshot reads, commit markers,
//!   checkpoint gating, a checkpoint counter for snapshot opens, and
//!   open-time recovery.
//!
//! The protocol never edits SQLite's shared memory. It reads the documented
//! wal-index header (walformat.html) while the writer holds the WAL write
//! lock, and repairs WAL files only when no connection has the set open.
const std = @import("std");
const c = @import("c");

fn bufPrintZ(buf: []u8, comptime fmt: []const u8, args: anytype) std.fmt.BufPrintError![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, fmt, args, 0);
}

pub const max_members = 32;
const shm_region_size = 32768;

// SQLite WAL constants (sqlite3.c: WAL_WRITE_LOCK, WAL_CKPT_LOCK, WAL_HDRSIZE,
// WAL_FRAME_HDRSIZE).
const wal_write_lock = 0;
const native_endian = @import("builtin").cpu.arch.endian();
const wal_ckpt_lock = 1;
/// WAL_READ_LOCK(0): a checkpointer takes it after choosing how far to
/// copy and before recording that choice (nBackfillAttempted).
const wal_read_lock0 = 3;
const wal_header_size = 32;
const wal_frame_header_size = 24;

fn envU64(name: [*:0]const u8) ?u64 {
    const value = c.getenv(name);
    if (value == null) return null;
    return std.fmt.parseInt(u64, std.mem.span(value), 10) catch null;
}

// ---------------------------------------------------------------------------
// Fault injection
// ---------------------------------------------------------------------------

pub const fault = struct {
    var events: u64 = 0;
    var crash_at: u64 = 0;
    var crash_tag: ?[]const u8 = null;
    var tagged: u64 = 0;
    var trace: bool = false;
    var rng: u64 = 0x9e3779b97f4a7c15;
    pub var powerloss: bool = false;
    /// Test-only protocol mutations, to show the tests detect each defect:
    /// "no-gate" (no seqlock window), "no-lock-gate", "no-ckpt-gate",
    /// "no-seq-check", "no-snapshot-open", "no-solo-window", "no-markers",
    /// "no-marker-rollback", "no-cross-flag", "no-ckpt-validate" (accept a
    /// skipped checkpoint lock without checking the counter), "no-ckpt-skip"
    /// (always take the real lock), "no-ckpt-reset" (a writer does not clear
    /// checkpointers left by dead processes), "no-discard-unpublished" (a
    /// writer keeps frames a dead writer wrote past mxFrame), "no-txn-epoch"
    /// (marker numbers continue from the newest published one), "no-open-gate"
    /// (opens and closes do not take the open/close gate), "no-late-alone"
    /// (no `-alive` check after SQLite has mapped the wal-indexes),
    /// "no-early-heads" (the late-alone path reads the wal-index heads after
    /// SQLite has mapped them), "heads-process-wide" (a shared open reads
    /// the heads only when no other handle of this process is registered,
    /// the condition before T2), "no-ownership" (no member ownership).
    pub var mutate: []const u8 = "";
    pub var syncs: u64 = 0;
    /// I/O error injection: with CWAL_FAIL_TAG (a comma-separated list of
    /// operation tags, see `shouldFail`) and CWAL_FAIL_AT=n, the nth matching
    /// operation fails; with CWAL_FAIL_STICKY=1 every later one fails too
    /// (a full or dying disk). CWAL_FAIL_KIND=full makes writes fail with
    /// SQLITE_FULL (ENOSPC) instead of SQLITE_IOERR_WRITE (EIO).
    var fail_tag: ?[]const u8 = null;
    var fail_at: u64 = 0;
    var fail_sticky: bool = false;
    pub var fail_full: bool = false;
    var fail_seen: u64 = 0;
    var failures: u64 = 0;
    /// Test-only (CWAL_DEBUG=1): protocol decisions appended to
    /// `<main>-cwal-debug`.
    pub var debug: bool = false;

    pub fn init() void {
        crash_at = envU64("CWAL_CRASH_AT") orelse 0;
        powerloss = (envU64("CWAL_POWERLOSS") orelse 0) != 0;
        trace = (envU64("CWAL_TRACE") orelse 0) != 0;
        // With CWAL_CRASH_TAG (a comma-separated list), CWAL_CRASH_AT counts
        // only events with one of those tags.
        if (c.getenv("CWAL_CRASH_TAG")) |tag| crash_tag = std.mem.span(tag);
        if (c.getenv("CWAL_MUTATE")) |m| mutate = std.mem.span(m);
        debug = (envU64("CWAL_DEBUG") orelse 0) != 0;
        rng ^= (envU64("CWAL_SEED") orelse 1) *% 0x2545f4914f6cdd1d;
        if (c.getenv("CWAL_FAIL_TAG")) |tag| fail_tag = std.mem.span(tag);
        fail_at = envU64("CWAL_FAIL_AT") orelse 0;
        fail_sticky = (envU64("CWAL_FAIL_STICKY") orelse 0) != 0;
        if (c.getenv("CWAL_FAIL_KIND")) |kind| fail_full = std.mem.eql(u8, std.mem.span(kind), "full");
    }

    /// Whether this operation must fail (see `fail_tag`). Tags: write-wal,
    /// write-db, write-other, sync-wal, sync-db, sync-other, truncate,
    /// read-wal, read-db, open-wal, open-db, recover-truncate, recover-fsync,
    /// discard-truncate, discard-fsync.
    pub fn shouldFail(tag: []const u8) bool {
        const want = fail_tag orelse return false;
        var it = std.mem.splitScalar(u8, want, ',');
        while (it.next()) |w| {
            if (!std.mem.eql(u8, tag, w)) continue;
            const n = @atomicRmw(u64, &fail_seen, .Add, 1, .seq_cst) + 1;
            if (fail_at == 0 or n < fail_at or (n > fail_at and !fail_sticky)) return false;
            _ = @atomicRmw(u64, &failures, .Add, 1, .seq_cst);
            if (trace) std.debug.print("fail {d} {s}\n", .{ n, tag });
            return true;
        }
        return false;
    }

    /// Operations matching CWAL_FAIL_TAG so far, and how many were failed.
    pub fn failSeen() u64 {
        return @atomicLoad(u64, &fail_seen, .seq_cst);
    }

    pub fn failureCount() u64 {
        return @atomicLoad(u64, &failures, .seq_cst);
    }

    /// CWAL_MUTATE is a comma-separated list of test-only defects.
    pub fn mutated(name: []const u8) bool {
        var it = std.mem.tokenizeScalar(u8, mutate, ',');
        while (it.next()) |m| if (std.mem.eql(u8, m, name)) return true;
        return false;
    }

    pub fn count() u64 {
        return @atomicLoad(u64, &events, .seq_cst);
    }

    /// Events matching CWAL_CRASH_TAG so far.
    pub fn taggedCount() u64 {
        return @atomicLoad(u64, &tagged, .seq_cst);
    }

    pub fn event(tag: []const u8) void {
        const n = @atomicRmw(u64, &events, .Add, 1, .seq_cst) + 1;
        if (trace) std.debug.print("event {d} {s}\n", .{ n, tag });
        if (crash_tag != null) crashTagged(tag) else if (crash_at != 0 and n == crash_at) crash();
    }

    /// A crash point that only CWAL_CRASH_TAG selects. It is not an event,
    /// so untagged CWAL_CRASH_AT numbers stay as they were. Probes:
    /// commit-sync-first (a WAL sync in a cross-file commit before its
    /// window opens: no member has published), commit-sync-next (a WAL sync
    /// with the window open: earlier members have published, this one is
    /// durable but not published).
    pub fn probe(tag: []const u8) void {
        if (trace) std.debug.print("probe {s}\n", .{tag});
        crashTagged(tag);
    }

    fn crashTagged(tag: []const u8) void {
        const want = crash_tag orelse return;
        var it = std.mem.splitScalar(u8, want, ',');
        while (it.next()) |w| {
            if (!std.mem.eql(u8, tag, w)) continue;
            if (@atomicRmw(u64, &tagged, .Add, 1, .seq_cst) + 1 == crash_at) crash();
            return;
        }
    }

    pub fn random() u64 {
        rng ^= rng << 13;
        rng ^= rng >> 7;
        rng ^= rng << 17;
        return rng;
    }

    pub fn crash() noreturn {
        if (powerloss) overlay.powerLoss();
        _ = c.kill(c.getpid(), c.SIGKILL);
        while (true) _ = c.pause();
    }
};

/// Power-loss model. While enabled, writes stay in memory until the file is
/// synced, as if they sat in a volatile cache. A crash persists a random
/// subset of them: each is dropped, written, torn to a prefix at 512-byte
/// granularity, or scattered (each 512-byte sector written or not), so
/// unsynced writes can be lost, reordered or torn. Metadata is volatile
/// too, until the operation SQLite or the protocol uses to make it durable:
/// a truncation until the file is synced (a crash may restore the cut
/// bytes); a new file's directory entry until its directory is synced (a
/// crash may remove the file); a deletion likewise (a crash may bring the
/// file back). SQLite syncs the directory at a new WAL's first sync and
/// never when it deletes a WAL. A sync that fails (injected) persists some
/// of the file's pending writes and keeps the rest only in this process's
/// view, never on disk, as Linux may after a writeback error. Single-threaded
/// use only: power-loss runs use one writer process.
const overlay = struct {
    const Pending = struct { offset: i64, data: []u8 };
    const Slot = struct {
        path: [:0]u8,
        pending: std.ArrayList(Pending) = .empty,
        /// Writes a failed sync did not persist: visible here, never on disk.
        ghosts: std.ArrayList(Pending) = .empty,
        /// An unsynced truncation: the bytes it cut.
        undo: ?Pending = null,
        /// The directory entry was created and its directory not synced since.
        created: bool = false,
        /// Deleted without a directory sync: the file, renamed aside.
        deleted: ?[:0]u8 = null,
    };
    var slots: std.ArrayList(Slot) = .empty;
    const allocator = std.heap.c_allocator;
    /// What the last power loss did, for CWAL_PL_LOG.
    var lost_entries: u64 = 0;
    var revived: u64 = 0;
    var undone_truncates: u64 = 0;
    var scattered: u64 = 0;
    var ghost_writes: u64 = 0;
    var unsynced_writes: u64 = 0;

    fn find(path: []const u8, create: bool) ?*Slot {
        for (slots.items) |*slot| if (std.mem.eql(u8, slot.path, path)) return slot;
        if (!create) return null;
        const owned = allocator.dupeSentinel(u8, path, 0) catch @panic("oom");
        slots.append(allocator, .{ .path = owned }) catch @panic("oom");
        return &slots.items[slots.items.len - 1];
    }

    fn add(path: []const u8, offset: i64, bytes: []const u8) void {
        const slot = find(path, true).?;
        const copy = allocator.dupe(u8, bytes) catch @panic("oom");
        slot.pending.append(allocator, .{ .offset = offset, .data = copy }) catch @panic("oom");
    }

    fn hasWrites(slot: *Slot) bool {
        return slot.pending.items.len != 0 or slot.ghosts.items.len != 0;
    }

    fn maxEnd(slot: *Slot) i64 {
        var end: i64 = 0;
        for ([_][]Pending{ slot.ghosts.items, slot.pending.items }) |list| {
            for (list) |p| end = @max(end, p.offset + @as(i64, @intCast(p.data.len)));
        }
        return end;
    }

    fn applyTo(slot: *Slot, buffer: []u8, offset: i64) void {
        for ([_][]Pending{ slot.ghosts.items, slot.pending.items }) |list| {
            for (list) |p| {
                const start = @max(offset, p.offset);
                const end = @min(offset + @as(i64, @intCast(buffer.len)), p.offset + @as(i64, @intCast(p.data.len)));
                if (start >= end) continue;
                const dst = buffer[@intCast(start - offset)..@intCast(end - offset)];
                @memcpy(dst, p.data[@intCast(start - p.offset)..@intCast(end - p.offset)]);
            }
        }
    }

    fn writeRaw(path: [:0]const u8, offset: i64, bytes: []const u8) void {
        const fd = c.open(path.ptr, c.O_WRONLY | c.O_CLOEXEC);
        if (fd < 0) return;
        defer _ = c.close(fd);
        _ = c.pwrite(fd, bytes.ptr, bytes.len, offset);
    }

    fn freeList(list: *std.ArrayList(Pending)) void {
        for (list.items) |p| allocator.free(p.data);
        list.clearRetainingCapacity();
    }

    fn flush(path: []const u8) void {
        const slot = find(path, false) orelse return;
        for (slot.pending.items) |p| writeRaw(slot.path, p.offset, p.data);
        freeList(&slot.pending);
    }

    fn discard(path: []const u8) void {
        const slot = find(path, false) orelse return;
        freeList(&slot.pending);
        freeList(&slot.ghosts);
    }

    /// An injected sync failure: some pending writes reach the disk, the
    /// rest stay visible to this process only.
    fn failSync(path: []const u8) void {
        const slot = find(path, false) orelse return;
        for (slot.pending.items) |p| {
            if (fault.random() % 2 == 0) {
                writeRaw(slot.path, p.offset, p.data);
                allocator.free(p.data);
            } else {
                slot.ghosts.append(allocator, p) catch @panic("oom");
                ghost_writes += 1;
            }
        }
        slot.pending.clearRetainingCapacity();
    }

    /// A successful sync: the file's truncation is durable, and with
    /// `dir_sync` so is every directory change in its directory.
    fn synced(path: []const u8, dir_sync: bool) void {
        if (find(path, false)) |slot| {
            if (slot.undo) |u| allocator.free(u.data);
            slot.undo = null;
        }
        if (dir_sync) dirSynced(path);
    }

    fn dirName(path: []const u8) []const u8 {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return ".";
        return path[0..slash];
    }

    fn dirSynced(path: []const u8) void {
        const dir = dirName(path);
        for (slots.items) |*slot| {
            if (!std.mem.eql(u8, dirName(slot.path), dir)) continue;
            slot.created = false;
            if (slot.deleted) |saved| {
                _ = c.unlink(saved.ptr);
                allocator.free(saved);
                slot.deleted = null;
            }
        }
    }

    fn created(path: []const u8) void {
        find(path, true).?.created = true;
    }

    /// Before truncating `path` to `size` (earlier writes already flushed):
    /// keep the bytes a crash before the next sync may bring back. Two
    /// unsynced truncations are lost or kept together.
    fn truncating(path: []const u8, size: i64) void {
        const slot = find(path, true).?;
        var i: usize = 0;
        while (i < slot.ghosts.items.len) {
            const g = &slot.ghosts.items[i];
            if (g.offset >= size) {
                allocator.free(g.data);
                _ = slot.ghosts.swapRemove(i);
                continue;
            }
            const end = g.offset + @as(i64, @intCast(g.data.len));
            if (end > size) g.data = g.data[0..@intCast(size - g.offset)];
            i += 1;
        }
        const fd = c.open(slot.path.ptr, c.O_RDONLY | c.O_CLOEXEC);
        if (fd < 0) return;
        defer _ = c.close(fd);
        var end = fileSize(fd) orelse return;
        if (slot.undo) |u| {
            if (size >= u.offset) return;
            end = u.offset;
        }
        if (end <= size) return;
        const cut = allocator.alloc(u8, @intCast(end - size)) catch @panic("oom");
        if (c.pread(fd, cut.ptr, cut.len, size) != cut.len) {
            allocator.free(cut);
            return;
        }
        if (slot.undo) |u| {
            const joined = std.mem.concat(allocator, u8, &.{ cut, u.data }) catch @panic("oom");
            allocator.free(cut);
            allocator.free(u.data);
            slot.undo = .{ .offset = size, .data = joined };
        } else slot.undo = .{ .offset = size, .data = cut };
    }

    /// Delete `path` as a file system without a directory sync would: the
    /// file is renamed aside and may come back at a crash. Returns the
    /// unix VFS result for a missing file.
    fn delete(path: [:0]const u8, sync_dir: c_int) c_int {
        if (c.access(path.ptr, c.F_OK) != 0) return unix_vfs.*.xDelete.?(unix_vfs, path.ptr, sync_dir);
        const slot = find(path, true).?;
        freeList(&slot.pending);
        freeList(&slot.ghosts);
        if (slot.undo) |u| allocator.free(u.data);
        slot.undo = null;
        if (slot.created or slot.deleted != null) {
            // Its creation was never durable: at a crash the older file (if
            // a deletion before it was not durable either) or nothing.
            _ = c.unlink(path.ptr);
            slot.created = false;
        } else {
            const saved = std.fmt.allocPrintSentinel(allocator, "{s}-cwal-deleted", .{path}, 0) catch @panic("oom");
            if (c.rename(path.ptr, saved.ptr) != 0) {
                allocator.free(saved);
                return c.SQLITE_IOERR_DELETE;
            }
            slot.deleted = saved;
        }
        if (sync_dir & 1 != 0) dirSynced(path);
        return c.SQLITE_OK;
    }

    fn flushAll() void {
        for (slots.items) |*slot| {
            flush(slot.path);
            // A failed sync's writes never reach the disk.
            freeList(&slot.ghosts);
            if (slot.deleted) |saved| {
                _ = c.unlink(saved.ptr);
                allocator.free(saved);
                slot.deleted = null;
            }
        }
    }

    fn powerLoss() void {
        for (slots.items) |*slot| {
            if (slot.deleted) |saved| {
                if (fault.random() % 2 == 0) {
                    // The deletion (and any re-creation) is lost.
                    _ = c.rename(saved.ptr, slot.path.ptr);
                    revived += 1;
                    continue;
                }
                _ = c.unlink(saved.ptr);
            }
            if (slot.created and fault.random() % 3 == 0) {
                _ = c.unlink(slot.path.ptr);
                lost_entries += 1;
                continue;
            }
            if (slot.undo) |u| {
                if (fault.random() % 2 == 0) {
                    writeRaw(slot.path, u.offset, u.data);
                    undone_truncates += 1;
                }
            }
            for (slot.pending.items) |p| {
                unsynced_writes += 1;
                switch (fault.random() % 4) {
                    0 => {},
                    1 => writeRaw(slot.path, p.offset, p.data),
                    2 => {
                        const sectors = (p.data.len + 511) / 512;
                        const keep = @min(p.data.len, (fault.random() % (sectors + 1)) * 512);
                        writeRaw(slot.path, p.offset, p.data[0..keep]);
                    },
                    else => {
                        var s: usize = 0;
                        while (s < p.data.len) : (s += 512) {
                            if (fault.random() % 2 == 0) writeRaw(slot.path, p.offset + @as(i64, @intCast(s)), p.data[s..@min(p.data.len, s + 512)]);
                        }
                        scattered += 1;
                    },
                }
            }
        }
        if (c.getenv("CWAL_PL_LOG")) |log_path| {
            const fd = c.open(log_path, c.O_WRONLY | c.O_CREAT | c.O_APPEND | c.O_CLOEXEC, @as(c_uint, 0o644));
            if (fd >= 0) {
                var buf: [256]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "pl unsynced_writes={d} lost_entries={d} revived={d} undone_truncates={d} scattered={d} ghosts={d} failures={d}\n", .{ unsynced_writes, lost_entries, revived, undone_truncates, scattered, ghost_writes, fault.failureCount() }) catch "";
                _ = c.write(fd, line.ptr, line.len);
                _ = c.close(fd);
            }
        }
    }
};

/// Persist writes held by the power-loss model. Call before a normal exit.
pub fn flushPending() void {
    if (fault.powerloss) overlay.flushAll();
}

/// Truncate `fd` (the file at `path`) to `size` and sync it, with fault
/// events, injectable failures and the power-loss model's volatile
/// truncation.
fn truncateDurably(fd: c_int, path: [:0]const u8, size: i64, comptime tag: []const u8) Error!void {
    fault.event(tag ++ "-truncate");
    if (fault.shouldFail(tag ++ "-truncate")) return error.Io;
    if (fault.powerloss) overlay.truncating(path, size);
    if (c.ftruncate(fd, size) != 0) return error.Io;
    fault.event(tag ++ "-fsync");
    if (fault.shouldFail(tag ++ "-fsync")) return error.Io;
    if (c.fsync(fd) != 0) return error.Io;
    if (fault.powerloss) overlay.synced(path, false);
}

// ---------------------------------------------------------------------------
// VFS
// ---------------------------------------------------------------------------

const Kind = enum(u8) { main_db, wal, other };

const File = extern struct {
    base: c.sqlite3_file,
    real: [*c]c.sqlite3_file,
    path: [*c]const u8,
    kind: Kind,
    member: u8,
    conn_id: u32,
    /// The first wal-index region, once mapped (test checks only).
    shm0: ?*anyopaque,
    /// A WAL opened for creation: SQLite's unix VFS syncs the directory at
    /// its first sync (power-loss model only).
    dir_sync_pending: bool,
};

var unix_vfs: [*c]c.sqlite3_vfs = null;
var cwal_vfs: c.sqlite3_vfs = undefined;

/// Test-only delays that widen races.
pub const test_delay = struct {
    /// Sleep inside the publication window.
    pub var window_delay_us: u32 = 0;
    /// Test-only: sleep inside a snapshot open's checkpoint-lock region, and
    /// inside a checkpoint between choosing its end frame and recording it,
    /// to widen the race the checkpoint counter must catch.
    pub var ckpt_open_delay_us: u32 = 0;
    pub var ckpt_scan_delay_us: u32 = 0;
    /// Sleep after an opener found another handle holding `-alive`, before
    /// SQLite maps the wal-indexes: widens the window in which that handle
    /// can die (see aloneAfterMapping).
    pub var alive_delay_us: u32 = 0;
    /// `CWAL_DELAY_POINTS=name=us[,name=us...]`: sleep at named points
    /// around the checkpoint counter (see `point`).
    var points: [8]struct { name: []const u8, us: u32 } = undefined;
    var npoints: usize = 0;

    fn parsePoints() void {
        const value = c.getenv("CWAL_DELAY_POINTS");
        if (value == null) return;
        var it = std.mem.tokenizeScalar(u8, std.mem.span(value), ',');
        while (it.next()) |item| {
            const eq = std.mem.indexOfScalar(u8, item, '=') orelse continue;
            if (npoints == points.len) break;
            points[npoints] = .{ .name = item[0..eq], .us = std.fmt.parseInt(u32, item[eq + 1 ..], 10) catch continue };
            npoints += 1;
        }
    }

    /// A crash point (fault event) and an optional test delay. Points:
    /// ckpt-pre-inc (exclusive checkpoint lock granted, counter not yet
    /// raised), ckpt-locked (raised), ckpt-pre-dec (checkpoint done, count
    /// not yet retired), ckpt-post-dec (retired, real lock not yet
    /// released), open-take and open-release (a snapshot open's skipped
    /// shared lock, before it reads the counter), reset-held (a writer
    /// holds every member's checkpoint lock, before it clears the count).
    pub fn point(name: []const u8) void {
        fault.event(name);
        for (points[0..npoints]) |p| {
            if (std.mem.eql(u8, p.name, name)) _ = c.usleep(p.us);
        }
    }

    /// `CWAL_PAUSE_AT=name` with `CWAL_PAUSE_FILE=path`: the first time this
    /// process reaches pause point `name`, it creates `path.reached` and
    /// waits until `path.go` exists (exit 5 after 30 s), so a test can act
    /// at that exact point. Not an event. Points: open-shared (a shared open
    /// has read the wal-index heads; SQLite has not mapped them yet).
    var pause_at: ?[]const u8 = null;
    var pause_file: ?[]const u8 = null;
    var paused: bool = false;

    pub fn pause(name: []const u8) void {
        const want = pause_at orelse return;
        const base = pause_file orelse return;
        if (!std.mem.eql(u8, want, name) or @atomicRmw(bool, &paused, .Xchg, true, .seq_cst)) return;
        var buf: [1100]u8 = undefined;
        const reached = bufPrintZ(&buf, "{s}.reached", .{base}) catch return;
        const fd = c.open(reached.ptr, c.O_WRONLY | c.O_CREAT | c.O_CLOEXEC, @as(c_uint, 0o644));
        if (fd >= 0) _ = c.close(fd);
        const go = bufPrintZ(&buf, "{s}.go", .{base}) catch return;
        const deadline = monotonicNs() + 30 * std.time.ns_per_s;
        while (c.access(go.ptr, c.F_OK) != 0) {
            if (monotonicNs() > deadline) {
                std.debug.print("pause {s}: timed out\n", .{name});
                c._exit(5);
            }
            _ = c.usleep(1000);
        }
    }
};

pub fn register() void {
    fault.init();
    test_delay.window_delay_us = @intCast(envU64("CWAL_WINDOW_DELAY_US") orelse 0);
    test_delay.ckpt_open_delay_us = @intCast(envU64("CWAL_CKPT_OPEN_DELAY_US") orelse 0);
    test_delay.ckpt_scan_delay_us = @intCast(envU64("CWAL_CKPT_SCAN_DELAY_US") orelse 0);
    test_delay.alive_delay_us = @intCast(envU64("CWAL_ALIVE_DELAY_US") orelse 0);
    test_delay.parsePoints();
    if (c.getenv("CWAL_PAUSE_AT")) |v| test_delay.pause_at = std.mem.span(v);
    if (c.getenv("CWAL_PAUSE_FILE")) |v| test_delay.pause_file = std.mem.span(v);
    unix_vfs = c.sqlite3_vfs_find("unix");
    std.debug.assert(unix_vfs != null);
    cwal_vfs = unix_vfs.*;
    cwal_vfs.iVersion = 2;
    cwal_vfs.pNext = null;
    cwal_vfs.zName = "cwal";
    cwal_vfs.szOsFile = @intCast(@sizeOf(File) + @as(usize, @intCast(unix_vfs.*.szOsFile)));
    cwal_vfs.xOpen = &vfsOpen;
    cwal_vfs.xDelete = &vfsDelete;
    _ = c.sqlite3_vfs_register(&cwal_vfs, 0);
}

fn asFile(p: [*c]c.sqlite3_file) *File {
    return @ptrCast(@alignCast(p));
}

fn realMethods(f: *File) *const c.sqlite3_io_methods {
    return f.real.*.pMethods;
}

fn pathSlice(f: *File) []const u8 {
    return std.mem.span(f.path);
}

fn vfsOpen(vfs: [*c]c.sqlite3_vfs, name: c.sqlite3_filename, file: [*c]c.sqlite3_file, flags: c_int, out_flags: [*c]c_int) callconv(.c) c_int {
    _ = vfs;
    const f = asFile(file);
    f.base.pMethods = null;
    f.real = @ptrCast(@alignCast(@as([*]u8, @ptrCast(f)) + @sizeOf(File)));
    f.path = name;
    f.kind = if (flags & c.SQLITE_OPEN_MAIN_DB != 0) .main_db else if (flags & c.SQLITE_OPEN_WAL != 0) .wal else .other;
    f.member = 0;
    f.conn_id = 0;
    f.shm0 = null;
    f.dir_sync_pending = false;
    if (name != null and f.kind != .other) {
        if (c.sqlite3_uri_parameter(name, "cwal")) |id| f.conn_id = std.fmt.parseInt(u32, std.mem.span(id), 10) catch 0;
        if (c.sqlite3_uri_parameter(name, "cwm")) |m| f.member = std.fmt.parseInt(u8, std.mem.span(m), 10) catch 0;
    }
    if (f.kind != .other and fault.shouldFail(if (f.kind == .wal) "open-wal" else "open-db")) return c.SQLITE_CANTOPEN;
    const creating = name != null and flags & c.SQLITE_OPEN_CREATE != 0 and c.access(name, c.F_OK) != 0;
    const rc = unix_vfs.*.xOpen.?(unix_vfs, name, f.real, flags, out_flags);
    if (rc != c.SQLITE_OK) {
        if (f.real.*.pMethods != null) _ = f.real.*.pMethods.*.xClose.?(f.real);
        return rc;
    }
    f.base.pMethods = &io_methods;
    if (creating) {
        if (fault.powerloss) overlay.created(std.mem.span(name));
        fault.event("open-create");
    }
    f.dir_sync_pending = f.kind == .wal and flags & c.SQLITE_OPEN_CREATE != 0;
    if (f.kind == .main_db) {
        if (connFor(f)) |conn| conn.member_db[f.member] = f;
    }
    return rc;
}

fn vfsDelete(vfs: [*c]c.sqlite3_vfs, name: [*c]const u8, sync_dir: c_int) callconv(.c) c_int {
    _ = vfs;
    fault.event("delete");
    if (fault.powerloss) return overlay.delete(std.mem.span(name), sync_dir);
    return unix_vfs.*.xDelete.?(unix_vfs, name, sync_dir);
}

const io_methods = c.sqlite3_io_methods{
    // Version 2: shared memory but no xFetch, so SQLite never maps database
    // pages and every read passes through the power-loss model.
    .iVersion = 2,
    .xClose = &ioClose,
    .xRead = &ioRead,
    .xWrite = &ioWrite,
    .xTruncate = &ioTruncate,
    .xSync = &ioSync,
    .xFileSize = &ioFileSize,
    .xLock = &ioLock,
    .xUnlock = &ioUnlock,
    .xCheckReservedLock = &ioCheckReservedLock,
    .xFileControl = &ioFileControl,
    .xSectorSize = &ioSectorSize,
    .xDeviceCharacteristics = &ioDeviceCharacteristics,
    .xShmMap = &ioShmMap,
    .xShmLock = &ioShmLock,
    .xShmBarrier = &ioShmBarrier,
    .xShmUnmap = &ioShmUnmap,
};

fn ioClose(file: [*c]c.sqlite3_file) callconv(.c) c_int {
    const f = asFile(file);
    if (f.kind == .main_db) {
        if (connFor(f)) |conn| {
            if (conn.member_db[f.member] == f) conn.member_db[f.member] = null;
        }
    }
    return realMethods(f).xClose.?(f.real);
}

fn realSize(f: *File) i64 {
    var size: c.sqlite3_int64 = 0;
    if (realMethods(f).xFileSize.?(f.real, &size) != c.SQLITE_OK) return 0;
    return size;
}

fn ioRead(file: [*c]c.sqlite3_file, buffer: ?*anyopaque, amount: c_int, offset: c.sqlite3_int64) callconv(.c) c_int {
    const f = asFile(file);
    if (f.kind != .other and fault.shouldFail(if (f.kind == .wal) "read-wal" else "read-db")) return c.SQLITE_IOERR_READ;
    if (!fault.powerloss) return realMethods(f).xRead.?(f.real, buffer, amount, offset);
    const slot = overlay.find(pathSlice(f), false) orelse return realMethods(f).xRead.?(f.real, buffer, amount, offset);
    if (!overlay.hasWrites(slot)) return realMethods(f).xRead.?(f.real, buffer, amount, offset);
    const bytes = @as([*]u8, @ptrCast(buffer.?))[0..@intCast(amount)];
    const logical = @max(realSize(f), overlay.maxEnd(slot));
    var rc = realMethods(f).xRead.?(f.real, buffer, amount, offset);
    if (rc != c.SQLITE_OK and rc != c.SQLITE_IOERR_SHORT_READ) return rc;
    overlay.applyTo(slot, bytes, offset);
    rc = c.SQLITE_OK;
    if (offset + amount > logical) {
        const valid: usize = if (logical > offset) @intCast(logical - offset) else 0;
        @memset(bytes[valid..], 0);
        rc = c.SQLITE_IOERR_SHORT_READ;
    }
    return rc;
}

fn ioWrite(file: [*c]c.sqlite3_file, buffer: ?*const anyopaque, amount: c_int, offset: c.sqlite3_int64) callconv(.c) c_int {
    const f = asFile(file);
    const tag = switch (f.kind) {
        .main_db => "write-db",
        .wal => "write-wal",
        .other => "write-other",
    };
    fault.event(tag);
    const bytes = @as([*]const u8, @ptrCast(buffer.?))[0..@intCast(amount)];
    if (f.kind == .wal) {
        if (connFor(f)) |conn| {
            if (!conn.observeWalWrite(bytes)) return c.SQLITE_IOERR_WRITE;
        }
    }
    if (fault.shouldFail(tag)) {
        // A failed write may have written a prefix of its sectors.
        const sectors = (bytes.len + 511) / 512;
        const keep = @min(bytes.len, (fault.random() % (sectors + 1)) * 512);
        if (keep != 0) {
            if (fault.powerloss) overlay.add(pathSlice(f), offset, bytes[0..keep]) else _ = realMethods(f).xWrite.?(f.real, bytes.ptr, @intCast(keep), offset);
        }
        return if (fault.fail_full) c.SQLITE_FULL else c.SQLITE_IOERR_WRITE;
    }
    if (fault.powerloss) {
        overlay.add(pathSlice(f), offset, bytes);
        return c.SQLITE_OK;
    }
    return realMethods(f).xWrite.?(f.real, buffer, amount, offset);
}

fn ioTruncate(file: [*c]c.sqlite3_file, size: c.sqlite3_int64) callconv(.c) c_int {
    const f = asFile(file);
    fault.event("truncate");
    if (fault.shouldFail("truncate")) return c.SQLITE_IOERR_TRUNCATE;
    // Model truncation as ordered after earlier writes to the file, and
    // lost if the file is not synced before a crash.
    if (fault.powerloss) {
        overlay.flush(pathSlice(f));
        overlay.truncating(pathSlice(f), size);
    }
    return realMethods(f).xTruncate.?(f.real, size);
}

fn ioSync(file: [*c]c.sqlite3_file, flags: c_int) callconv(.c) c_int {
    const f = asFile(file);
    fault.event("sync");
    if (fault.shouldFail(switch (f.kind) {
        .main_db => "sync-db",
        .wal => "sync-wal",
        .other => "sync-other",
    })) {
        if (fault.powerloss) overlay.failSync(pathSlice(f));
        return c.SQLITE_IOERR_FSYNC;
    }
    if (fault.powerloss) overlay.flush(pathSlice(f));
    _ = @atomicRmw(u64, &fault.syncs, .Add, 1, .seq_cst);
    const rc = realMethods(f).xSync.?(f.real, flags);
    if (rc == c.SQLITE_OK and fault.powerloss) {
        overlay.synced(pathSlice(f), f.dir_sync_pending);
        f.dir_sync_pending = false;
    }
    fault.event("sync-done");
    if (f.kind == .wal) {
        // With synchronous=FULL, SQLite syncs a member's WAL after writing
        // its commit frame and before publishing it in the wal-index. The
        // first such sync of a commit starts the publication window.
        if (connFor(f)) |conn| {
            conn.log("wal sync member {d} in_commit={} window_open={} cross={}", .{ f.member, conn.in_commit, conn.window_open, conn.cross });
            if (rc == c.SQLITE_OK and conn.in_commit and conn.cross) fault.probe(if (conn.window_open) "commit-sync-next" else "commit-sync-first");
            // Fail the commit before this member publishes.
            if (rc == c.SQLITE_OK and !conn.startPublication()) return c.SQLITE_IOERR_FSYNC;
        }
    }
    return rc;
}

fn ioFileSize(file: [*c]c.sqlite3_file, out: [*c]c.sqlite3_int64) callconv(.c) c_int {
    const f = asFile(file);
    const rc = realMethods(f).xFileSize.?(f.real, out);
    if (rc == c.SQLITE_OK and fault.powerloss) {
        if (overlay.find(pathSlice(f), false)) |slot| out.* = @max(out.*, overlay.maxEnd(slot));
    }
    return rc;
}

fn ioLock(file: [*c]c.sqlite3_file, level: c_int) callconv(.c) c_int {
    const f = asFile(file);
    fault.event("lock");
    // In WAL mode SQLite takes an EXCLUSIVE database-file lock only to
    // checkpoint on close or to leave WAL mode, and while it holds that lock
    // it skips the shared-memory checkpoint lock. Gate it the same way.
    if (level == c.SQLITE_LOCK_EXCLUSIVE and f.kind == .main_db) {
        if (connFor(f)) |conn| {
            if (conn.mode == .cwal and !fault.mutated("no-lock-gate") and !conn.checkpointAllowed()) return c.SQLITE_BUSY;
        }
    }
    return realMethods(f).xLock.?(f.real, level);
}

fn ioUnlock(file: [*c]c.sqlite3_file, level: c_int) callconv(.c) c_int {
    const f = asFile(file);
    return realMethods(f).xUnlock.?(f.real, level);
}

fn ioCheckReservedLock(file: [*c]c.sqlite3_file, out: [*c]c_int) callconv(.c) c_int {
    const f = asFile(file);
    return realMethods(f).xCheckReservedLock.?(f.real, out);
}

fn ioFileControl(file: [*c]c.sqlite3_file, op: c_int, arg: ?*anyopaque) callconv(.c) c_int {
    const f = asFile(file);
    const rc = realMethods(f).xFileControl.?(f.real, op, arg);
    if (op == c.SQLITE_FCNTL_COMMIT_PHASETWO and f.kind == .main_db) {
        if (connFor(f)) |conn| conn.commitPhaseTwo();
    }
    return rc;
}

fn ioSectorSize(file: [*c]c.sqlite3_file) callconv(.c) c_int {
    const f = asFile(file);
    return realMethods(f).xSectorSize.?(f.real);
}

fn ioDeviceCharacteristics(file: [*c]c.sqlite3_file) callconv(.c) c_int {
    const f = asFile(file);
    return realMethods(f).xDeviceCharacteristics.?(f.real);
}

fn ioShmMap(file: [*c]c.sqlite3_file, page: c_int, size: c_int, extend: c_int, out: [*c]?*volatile anyopaque) callconv(.c) c_int {
    const f = asFile(file);
    const rc = realMethods(f).xShmMap.?(f.real, page, size, extend, out);
    if (rc == c.SQLITE_OK and page == 0 and out.* != null) f.shm0 = @volatileCast(out.*);
    return rc;
}

fn ioShmLock(file: [*c]c.sqlite3_file, offset: c_int, n: c_int, flags: c_int) callconv(.c) c_int {
    const f = asFile(file);
    fault.event("shm-lock");
    const conn = connFor(f);
    // Exclusive locks on the checkpoint byte: checkpoints, snapshot recovery
    // and wal-index recovery (which locks 1..2).
    const ckpt_exclusive = offset <= wal_ckpt_lock and wal_ckpt_lock < offset + n and flags & c.SQLITE_SHM_EXCLUSIVE != 0;
    if (conn) |cn| {
        if (cn.opening_seq != 0 and offset == wal_ckpt_lock and n == 1 and flags & c.SQLITE_SHM_SHARED != 0) {
            if (cn.ckptLockShared(f.member, flags & c.SQLITE_SHM_LOCK != 0)) return c.SQLITE_OK;
        }
        if (cn.mode == .cwal and offset == wal_ckpt_lock and n == 1 and flags == c.SQLITE_SHM_LOCK | c.SQLITE_SHM_EXCLUSIVE) {
            if (!fault.mutated("no-ckpt-gate") and !cn.checkpointAllowed()) return c.SQLITE_BUSY;
        }
        if (ckpt_exclusive and flags & c.SQLITE_SHM_UNLOCK != 0 and cn.ckpt_ex[f.member]) {
            // Retire the checkpointer after everything it wrote but before
            // it releases the lock: the counter includes a live process
            // exactly while it holds the lock (see resetCheckpointers).
            test_delay.point("ckpt-pre-dec");
            cn.ckpt_ex[f.member] = false;
            _ = @atomicRmw(u64, &cn.snap.?.ckpt, .Sub, 1, .seq_cst);
            test_delay.point("ckpt-post-dec");
        }
        if (cn.ckpt_ex[f.member] and offset == wal_read_lock0 and n == 1 and flags == c.SQLITE_SHM_LOCK | c.SQLITE_SHM_EXCLUSIVE and test_delay.ckpt_scan_delay_us != 0) {
            _ = c.usleep(test_delay.ckpt_scan_delay_us);
        }
    }
    const rc = realMethods(f).xShmLock.?(f.real, offset, n, flags);
    if (conn) |cn| {
        if (offset == 1 and n >= 2 and flags & c.SQLITE_SHM_EXCLUSIVE != 0 and flags & c.SQLITE_SHM_LOCK != 0)
            cn.log("wal-index recovery lock member {d} rc={d}", .{ f.member, rc });
        if (cn.mode == .cwal and ckpt_exclusive and flags & c.SQLITE_SHM_LOCK != 0 and rc == c.SQLITE_OK) {
            // Announce the checkpointer before SQLite, holding the lock, can
            // look at read marks or write anything.
            test_delay.point("ckpt-pre-inc");
            _ = @atomicRmw(u64, &cn.snap.?.ckpt, .Add, ckpt_started + 1, .seq_cst);
            // Full barrier: the increment must be visible before this
            // checkpointer loads any read mark (a reader stores its mark,
            // then loads the counter). On ARM64 a seq_cst read-modify-write
            // does not order later plain loads after its store. SQLite's
            // walIndexReadHdr also issues one before the scan.
            realMethods(f).xShmBarrier.?(f.real);
            cn.ckpt_ex[f.member] = true;
            cn.stats.ckpt_locks += 1;
            test_delay.point("ckpt-locked");
        }
        if (rc == c.SQLITE_OK and offset == wal_write_lock and n == 1) {
            if (flags == c.SQLITE_SHM_LOCK | c.SQLITE_SHM_EXCLUSIVE) cn.write_locked[f.member] = true;
            if (flags & c.SQLITE_SHM_UNLOCK != 0) cn.write_locked[f.member] = false;
        }
    }
    return rc;
}

fn ioShmBarrier(file: [*c]c.sqlite3_file) callconv(.c) void {
    const f = asFile(file);
    // SQLite issues barriers around wal-index header writes, so this marks
    // the points where a member publishes a commit.
    fault.event("shm-barrier");
    realMethods(f).xShmBarrier.?(f.real);
}

fn ioShmUnmap(file: [*c]c.sqlite3_file, delete_flag: c_int) callconv(.c) c_int {
    const f = asFile(file);
    return realMethods(f).xShmUnmap.?(f.real, delete_flag);
}

// ---------------------------------------------------------------------------
// WAL files and commit markers
// ---------------------------------------------------------------------------

/// SQLite's WAL checksum (sqlite3.c walChecksumBytes): words are big-endian
/// when the header magic has its low bit set, little-endian otherwise.
fn walChecksum(big: bool, bytes: []const u8, s: *[2]u32) void {
    const endian: std.builtin.Endian = if (big) .big else .little;
    var i: usize = 0;
    while (i < bytes.len) : (i += 8) {
        s[0] +%= std.mem.readInt(u32, bytes[i..][0..4], endian) +% s[1];
        s[1] +%= std.mem.readInt(u32, bytes[i + 4 ..][0..4], endian) +% s[0];
    }
}

const LastCommit = struct { start: i64, writes_page: bool };

/// The last commit in the WAL behind `fd`: the offset at which it starts (the
/// end of the commit before it, or the end of the header if it is the only
/// one), and whether one of its frames holds database page `page`. Frames
/// are accepted as SQLite's WAL recovery accepts them: the header is valid,
/// and each frame carries the header salts and continues the checksum
/// chain. Null if the WAL holds no valid commit.
fn walLastCommit(fd: c_int, page: u32) ?LastCommit {
    var header: [wal_header_size]u8 = undefined;
    if (c.pread(fd, &header, header.len, 0) != header.len) return null;
    const magic = std.mem.readInt(u32, header[0..4], .big);
    if (magic & 0xffff_fffe != 0x377f_0682) return null;
    const big = magic & 1 != 0;
    const page_size = std.mem.readInt(u32, header[8..12], .big);
    if (page_size < 512 or page_size > 65536 or page_size & (page_size - 1) != 0) return null;
    var s: [2]u32 = .{ 0, 0 };
    walChecksum(big, header[0..24], &s);
    if (s[0] != std.mem.readInt(u32, header[24..28], .big) or s[1] != std.mem.readInt(u32, header[28..32], .big)) return null;
    const frame_size: usize = wal_frame_header_size + page_size;
    const frame = std.heap.c_allocator.alloc(u8, frame_size) catch return null;
    defer std.heap.c_allocator.free(frame);
    var last: ?i64 = null;
    var prev: i64 = wal_header_size;
    var group_writes = false;
    var last_writes = false;
    var offset: i64 = wal_header_size;
    while (true) : (offset += @intCast(frame_size)) {
        if (c.pread(fd, frame.ptr, frame_size, offset) != frame_size) break;
        if (!std.mem.eql(u8, frame[8..16], header[16..24])) break;
        if (std.mem.readInt(u32, frame[0..4], .big) == 0) break;
        walChecksum(big, frame[0..8], &s);
        walChecksum(big, frame[wal_frame_header_size..], &s);
        if (s[0] != std.mem.readInt(u32, frame[16..20], .big) or s[1] != std.mem.readInt(u32, frame[20..24], .big)) break;
        if (std.mem.readInt(u32, frame[0..4], .big) == page) group_writes = true;
        if (std.mem.readInt(u32, frame[4..8], .big) != 0) {
            if (last) |end| prev = end;
            last = offset + @as(i64, @intCast(frame_size));
            last_writes = group_writes;
            group_writes = false;
        }
    }
    return if (last != null) .{ .start = prev, .writes_page = last_writes } else null;
}

/// `root` is the marker table's root page, which every marker update writes.
const Marker = struct { txn: u64 = 0, mask: u32 = 0, root: u32 = 0 };

/// The name SQLite gives a file: absolute, with symlinks resolved. SQLite
/// puts a database's -wal and -shm next to this name, so recovery and the
/// set's lock files must use it too.
fn fullPath(p: []const u8) Error![:0]u8 {
    const vfs = c.sqlite3_vfs_find("unix") orelse return error.Io;
    var in: [1100]u8 = undefined;
    const z = bufPrintZ(&in, "{s}", .{p}) catch return error.Io;
    var out: [1024]u8 = @splat(0);
    // SQLITE_OK_SYMLINK (SQLITE_OK with an extended code) means a symlink
    // was followed.
    if (vfs.*.xFullPathname.?(vfs, z.ptr, out.len, &out) & 0xff != c.SQLITE_OK) return error.Io;
    return std.heap.c_allocator.dupeSentinel(u8, std.mem.sliceTo(&out, 0), 0) catch error.Io;
}

/// Header and checkpoint info of a member's wal-index (`-shm`), read raw:
/// the first connection to open the member truncates it.
const ShmHead = [136]u8;

fn readShmHead(path: [:0]const u8) ?ShmHead {
    var buf: [1100]u8 = undefined;
    const shm_path = bufPrintZ(&buf, "{s}-shm", .{path}) catch return null;
    const fd = c.open(shm_path.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var shm: ShmHead = undefined;
    if (c.pread(fd, &shm, shm.len, 0) != shm.len) return null;
    return shm;
}

/// Whether a completed checkpoint copied WAL frames past byte offset keep
/// into the database file, according to the wal-index. CWAL checkpoints
/// only between commits, so this means a connection outside the protocol
/// checkpointed a torn commit; truncating the WAL would no longer remove it.
/// Detected: nBackfill past keep in this WAL's wal-index, or a wal-index one
/// restart ahead of this WAL (SQLite restarts a WAL only after checkpointing
/// all of it, and a writer that dies before writing the new WAL header
/// leaves the old frames). A checkpointer that died before finishing
/// (nBackfill not yet advanced), or a lost -shm, is not detected.
fn backfilledPast(head: ?ShmHead, wal_fd: c_int, keep: i64) bool {
    const shm = head orelse return false;
    // Two equal, initialised copies of the header.
    if (!std.mem.eql(u8, shm[0..48], shm[48..96]) or shm[12] == 0) return false;
    var header: [wal_header_size]u8 = undefined;
    if (c.pread(wal_fd, &header, header.len, 0) != header.len) return false;
    // A restart increments salt-1 (walRestartHdr); both are stored big-endian.
    if (std.mem.readInt(u32, shm[32..36], .big) == std.mem.readInt(u32, header[16..20], .big) +% 1) return true;
    if (!std.mem.eql(u8, shm[32..40], header[16..24])) return false;
    const frame_size: i64 = wal_frame_header_size + @as(i64, std.mem.readInt(u32, header[8..12], .big));
    const kept_frames = @divTrunc(keep - wal_header_size, frame_size);
    return std.mem.readInt(u32, shm[96..100], native_endian) > kept_frames;
}

/// A member's commit marker as SQLite sees the file (database plus valid
/// WAL frames). Opened through this VFS without a connection id, so the
/// power-loss model applies but no protocol hook runs; the connection does
/// not checkpoint on close.
fn readMarker(path: [:0]const u8) Error!Marker {
    var db: ?*c.sqlite3 = null;
    defer if (db) |d| {
        _ = c.sqlite3_close(d);
    };
    if (c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READWRITE, "cwal") != c.SQLITE_OK) return error.Sqlite;
    _ = c.sqlite3_db_config(db, c.SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, @as(c_int, 1), @as(?*c_int, null));
    var stmt: ?*c.sqlite3_stmt = null;
    // No table yet: no cross-file commit has happened.
    if (c.sqlite3_prepare_v2(db, "select txn, mask, (select rootpage from sqlite_schema where name = 'cwal_marker') from cwal_marker where k = 0", -1, &stmt, null) != c.SQLITE_OK) return .{};
    defer _ = c.sqlite3_finalize(stmt);
    return switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => .{ .txn = @intCast(c.sqlite3_column_int64(stmt, 0)), .mask = @intCast(c.sqlite3_column_int64(stmt, 1)), .root = @intCast(c.sqlite3_column_int64(stmt, 2)) },
        c.SQLITE_DONE => .{},
        else => error.Sqlite,
    };
}

/// Seqlock page shared by every handle of a set (`main.db-cwal-snap`). The
/// writer stores each member's wal-index header, then makes `seq` odd for
/// the publication window, and even again after it.
const SnapPage = extern struct {
    seq: u64,
    /// Commit markers: the current or last window belongs to a cross-file
    /// commit.
    cross: u32,
    /// Commit markers: a writer rolled back after a member published.
    broken: u32,
    /// Checkpoint counter: low 32 bits, checkpointers holding (or taking)
    /// the exclusive checkpoint lock on any member; high 32 bits, how many
    /// have started. See `Conn.ckptLockShared`.
    ckpt: u64,
    reserved: [40]u8,
    hdr: [max_members][48]u8,
};
const snap_page_size = 4096;
const ckpt_started: u64 = 1 << 32;

// ---------------------------------------------------------------------------
// Connections
// ---------------------------------------------------------------------------

pub const Mode = enum { plain, cwal };
pub const Role = enum { writer, reader };

pub const Error = error{ Sqlite, Broken, WriterBusy, Io, ProtocolViolation, MemberOwned };

pub const Options = struct {
    mode: Mode,
    role: Role,
    synchronous: [:0]const u8 = "FULL",
    cache_pages: i32 = 0,
    busy_timeout_ms: c_int = 10_000,
};

var registry: [256]?*Conn = @splat(null);
/// Per registry slot, the hash of its handle's set identity (`setHash`), 0
/// when free. Read instead of the other handle's `Conn`, which its owner
/// may be freeing.
var registry_set: [256]u64 = @splat(0);

/// Claim a free registry slot (1..255). Slot 0 means "not a CWAL file".
fn claimSlot(conn: *Conn) ?u32 {
    for (1..registry.len) |i| {
        if (@cmpxchgStrong(?*Conn, &registry[i], null, conn, .seq_cst, .seq_cst) == null) return @intCast(i);
    }
    return null;
}

fn connFor(f: *File) ?*Conn {
    if (f.conn_id == 0 or f.conn_id >= registry.len) return null;
    return registry[f.conn_id];
}

pub const Stats = struct {
    commits: u64 = 0,
    /// Time readers spent waiting for a publication window to end.
    window_wait_ns: u64 = 0,
    checkpoint_denied: u64 = 0,
    /// Reads that started inside a publication window and used snapshots.
    snapshot_reads: u64 = 0,
    /// Reads retried because a window started while pinning members.
    seq_retries: u64 = 0,
    /// Snapshot opens that failed, so the reader waited for the window.
    snapshot_waits: u64 = 0,
    /// Snapshot opens during which a checkpoint started (each is retried).
    ckpt_races: u64 = 0,
    /// Snapshot opens that took the real checkpoint lock because a
    /// checkpoint was running.
    ckpt_fallbacks: u64 = 0,
    /// Exclusive checkpoint locks this handle was granted (checkpoints,
    /// wal-index and snapshot recovery).
    ckpt_locks: u64 = 0,
    /// Times a writer's counter reset found another handle holding a
    /// member's checkpoint lock and waited.
    reset_waits: u64 = 0,
    /// WAL bytes past mxFrame that a writer dropped at open.
    discarded_bytes: u64 = 0,
};

pub const Conn = struct {
    id: u32,
    mode: Mode,
    role: Role,
    db: ?*c.sqlite3 = null,
    nmembers: u32,
    paths: [max_members][:0]u8 = undefined,
    member_db: [max_members]?*File = @splat(null),
    write_locked: [max_members]bool = @splat(false),
    alive_fd: c_int = -1,
    /// Per member, `-cwal-own`, held shared while this handle is open (see
    /// `acquireMembers`).
    own_fd: [max_members]c_int = @splat(-1),
    set_hash: u64 = 0,
    /// Open/close gate (`-gate`), held exclusively while this handle opens
    /// (until SQLite has mapped every member's wal-index) or closes.
    gate_fd: c_int = -1,
    gate_held: bool = false,
    /// This handle found `-alive` free at its open-time check.
    opened_alone: bool = false,
    /// Each member's wal-index head, read before SQLite mapped it (see
    /// `readShmHeads`).
    shm_heads: [max_members]?ShmHead = @splat(null),
    writer_fd: c_int = -1,
    live_fd: c_int = -1,
    snap_fd: c_int = -1,
    snap: ?*SnapPage = null,
    /// Number of the last cross-file transaction (its commit markers).
    txn: u64 = 0,
    /// The publication window is open: the seqlock is odd.
    window_open: bool = false,
    in_commit: bool = false,
    /// The commit in progress writes two or more members.
    cross: bool = false,
    /// `commit` wrote the markers of the commit in progress.
    marker_pending: bool = false,
    /// The commit in progress has written a commit frame to some member.
    any_commit_frame: bool = false,
    violation: bool = false,
    /// A statement of this handle's own is running: the authorizer lets it
    /// write the marker tables.
    internal: bool = false,
    /// Snapshot reads: the window (odd sequence) whose snapshots are being
    /// opened, 0 otherwise.
    opening_seq: u64 = 0,
    /// Per member, during a snapshot open: SQLite's shared checkpoint lock
    /// was granted without a real lock, at checkpoint count `ckpt_start`.
    ckpt_skipped: [max_members]bool = @splat(false),
    ckpt_start: [max_members]u32 = @splat(0),
    /// A checkpoint started while a skipped lock was "held".
    ckpt_race: bool = false,
    /// Per member: this handle holds an exclusive lock on the checkpoint
    /// byte that the counter includes.
    ckpt_ex: [max_members]bool = @splat(false),
    /// The current read uses snapshots, with these mxFrame values.
    snapshot_open: bool = false,
    snapshot_mx: [max_members]u32 = @splat(0),
    stats: Stats = .{},

    const allocator = std.heap.c_allocator;

    /// Open the set: `paths[0]` is the main database, the rest are attached
    /// as `m1`, `m2`, ... In CWAL mode the first handle to open a set that no
    /// other handle has open runs recovery.
    pub fn open(paths: []const []const u8, options: Options) Error!*Conn {
        const conn = allocator.create(Conn) catch return error.Io;
        conn.* = .{ .id = 0, .mode = options.mode, .role = options.role, .nmembers = @intCast(paths.len) };
        for (paths, 0..) |p, i| conn.paths[i] = fullPath(p) catch return error.Io;
        const id = claimSlot(conn) orelse return error.Io;
        conn.id = id;
        conn.set_hash = conn.setHash();
        @atomicStore(u64, &registry_set[id], conn.set_hash, .seq_cst);
        errdefer conn.close();

        if (options.mode == .cwal) {
            // The publication window starts at a commit-time WAL sync, which
            // SQLite issues only with synchronous=FULL or EXTRA.
            if (!std.ascii.eqlIgnoreCase(options.synchronous, "FULL") and !std.ascii.eqlIgnoreCase(options.synchronous, "EXTRA")) return error.ProtocolViolation;
            try conn.acquireMembers();
            try conn.openCoordination();
        }
        try conn.openSqlite(paths, options);
        if (options.mode == .cwal and try conn.aloneAfterMapping()) {
            // Every other handle closed or died between the `-alive` check
            // and SQLite mapping the wal-indexes, so this handle may have been
            // the first to map one, and SQLite then rebuilt it from the WAL
            // file, publishing any frames a dead writer left past mxFrame.
            // Recover as the first handle would have. Close without a
            // checkpoint: the rebuilt state may be torn.
            conn.log("alone after mapping", .{});
            _ = c.sqlite3_db_config(conn.db, c.SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, @as(c_int, 1), @as(?*c_int, null));
            _ = c.sqlite3_close_v2(conn.db);
            conn.db = null;
            if (fault.mutated("no-early-heads")) conn.readShmHeads();
            try conn.recoverAlone();
            try conn.openSqlite(paths, options);
        }
        if (options.mode == .cwal) {
            _ = c.sqlite3_commit_hook(conn.db, &commitHook, conn);
            _ = c.sqlite3_rollback_hook(conn.db, &rollbackHook, conn);
            if (options.role == .writer) {
                try conn.discardUnpublished();
                conn.resetCheckpointers();
                // One single-member commit per statement.
                for (0..paths.len) |i| {
                    var sql_buf: [160]u8 = undefined;
                    const schema = schemaName(i);
                    try conn.exec(bufPrintZ(&sql_buf, "create table if not exists {s}.cwal_marker(k integer primary key, txn integer not null, mask integer not null)", .{schema}) catch return error.Io);
                    try conn.exec(bufPrintZ(&sql_buf, "insert or ignore into {s}.cwal_marker values (0, 0, 0)", .{schema}) catch return error.Io);
                    const q = bufPrintZ(&sql_buf, "select txn from {s}.cwal_marker where k = 0", .{schema}) catch return error.Io;
                    conn.txn = @max(conn.txn, try conn.queryU64(q));
                }
                if (!fault.mutated("no-txn-epoch")) {
                    // Marker numbers identify one transaction for the life of
                    // the set, also when a writer died with a number in flight
                    // that recovery then removed: each writer takes a new epoch,
                    // durably, before it numbers anything, and numbers its
                    // transactions epoch << 32 | 1, 2, .... The epoch is in
                    // main's marker table, row 1.
                    try conn.exec("insert or ignore into main.cwal_marker values (1, 0, 0)");
                    const stored = try conn.queryU64("select txn from main.cwal_marker where k = 1");
                    const epoch = @max(stored, conn.txn >> 32) + 1;
                    var sql_buf: [96]u8 = undefined;
                    try conn.exec(bufPrintZ(&sql_buf, "update main.cwal_marker set txn = {d} where k = 1", .{epoch}) catch return error.Io);
                    conn.txn = epoch << 32;
                }
            }
            conn.releaseGate();
            _ = c.sqlite3_set_authorizer(conn.db, &authorize, conn);
        }
        return conn;
    }

    /// Statements the application may not run on a CWAL handle: writes to
    /// the marker tables, dropping or altering them or putting triggers on
    /// them, pragmas that would take a member out of the protocol (journal
    /// mode, locking mode, sync level, writable schema), and ATTACH or
    /// DETACH, which would change the set this handle commits.
    fn authorize(arg: ?*anyopaque, action: c_int, a1: [*c]const u8, a2: [*c]const u8, db_name: [*c]const u8, trigger: [*c]const u8) callconv(.c) c_int {
        _ = db_name;
        _ = trigger;
        const conn: *Conn = @ptrCast(@alignCast(arg.?));
        if (conn.internal or fault.mutated("no-authorizer")) return c.SQLITE_OK;
        const deny = switch (action) {
            c.SQLITE_INSERT, c.SQLITE_UPDATE, c.SQLITE_DELETE, c.SQLITE_DROP_TABLE, c.SQLITE_DROP_TEMP_TABLE => isMarker(a1),
            c.SQLITE_ALTER_TABLE, c.SQLITE_CREATE_TRIGGER, c.SQLITE_CREATE_TEMP_TRIGGER => isMarker(a2),
            c.SQLITE_PRAGMA => a2 != null and (isName(a1, "journal_mode") or isName(a1, "locking_mode") or isName(a1, "synchronous") or isName(a1, "writable_schema")),
            c.SQLITE_ATTACH, c.SQLITE_DETACH => true,
            else => false,
        };
        if (deny) conn.log("authorizer denied action {d} {s}", .{ action, if (a1 != null) std.mem.span(a1) else "" });
        return if (deny) c.SQLITE_DENY else c.SQLITE_OK;
    }

    fn isName(name: [*c]const u8, want: []const u8) bool {
        return name != null and std.ascii.eqlIgnoreCase(std.mem.span(name), want);
    }

    fn isMarker(name: [*c]const u8) bool {
        return isName(name, "cwal_marker");
    }

    /// After openSqlite, while the gate is held: whether no other handle has
    /// the set open any more although one had at the `-alive` check.
    fn aloneAfterMapping(conn: *Conn) Error!bool {
        if (conn.opened_alone or fault.mutated("no-late-alone")) return false;
        if (lock(conn.alive_fd, c.LOCK_EX | c.LOCK_NB)) return true;
        // A failed conversion drops the shared lock (flock(2)). Take it back:
        // only openers holding the gate take `-alive` exclusively.
        if (!lock(conn.alive_fd, c.LOCK_SH)) return error.Io;
        return false;
    }

    /// Open SQLite on every member and, in CWAL mode, map its wal-index.
    fn openSqlite(conn: *Conn, paths: []const []const u8, options: Options) Error!void {
        const id = conn.id;
        var uri_buf: [1024]u8 = undefined;
        const main_uri = bufPrintZ(&uri_buf, "file:{s}?cwal={d}&cwm=0", .{ conn.paths[0], id }) catch return error.Io;
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(main_uri.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_URI, "cwal") != c.SQLITE_OK) {
            std.debug.print("sqlite: open {s}: {s}\n", .{ conn.paths[0], c.sqlite3_errmsg(db) });
            if (db) |d| _ = c.sqlite3_close(d);
            return error.Sqlite;
        }
        conn.db = db;
        _ = c.sqlite3_busy_timeout(db, options.busy_timeout_ms);
        for (1..paths.len) |i| {
            var sql_buf: [1200]u8 = undefined;
            const sql = bufPrintZ(&sql_buf, "attach 'file:{s}?cwal={d}&cwm={d}' as m{d}", .{ conn.paths[i], id, i, i }) catch return error.Io;
            try conn.exec(sql);
        }
        for (0..paths.len) |i| {
            var sql_buf: [128]u8 = undefined;
            const schema = schemaName(i);
            try conn.exec(bufPrintZ(&sql_buf, "pragma {s}.synchronous={s}", .{ schema, options.synchronous }) catch return error.Io);
            if (options.cache_pages != 0) try conn.exec(bufPrintZ(&sql_buf, "pragma {s}.cache_size={d}", .{ schema, options.cache_pages }) catch return error.Io);
        }
        _ = c.sqlite3_wal_autocheckpoint(db, 0);
        if (options.mode == .cwal) {
            // Every member must be in WAL mode. Switch one that is not (WAL
            // mode persists); this fails while another connection has it
            // open in another mode.
            for (0..paths.len) |i| {
                var sql_buf: [64]u8 = undefined;
                const sql = bufPrintZ(&sql_buf, "pragma {s}.journal_mode=wal", .{schemaName(i)}) catch return error.Io;
                if (!try conn.queryIs(sql, "wal")) {
                    conn.log("member {d} is not in WAL mode", .{i});
                    return error.ProtocolViolation;
                }
            }
            // Read every member once, so each pager has its WAL open (which
            // sqlite3_snapshot_open requires) and its wal-index mapped.
            for (0..paths.len) |i| {
                var sql_buf: [96]u8 = undefined;
                try conn.exec(bufPrintZ(&sql_buf, "select count(*) from {s}.sqlite_schema", .{schemaName(i)}) catch return error.Io);
            }
        }
    }

    fn releaseGate(conn: *Conn) void {
        if (!conn.gate_held) return;
        _ = c.flock(conn.gate_fd, c.LOCK_UN);
        conn.gate_held = false;
    }

    const schema_names: [max_members][:0]const u8 = blk: {
        @setEvalBranchQuota(100_000);
        var names: [max_members][:0]const u8 = undefined;
        names[0] = "main";
        for (1..max_members) |i| names[i] = std.fmt.comptimePrint("m{d}", .{i});
        break :blk names;
    };

    pub fn schemaName(i: usize) [:0]const u8 {
        return schema_names[i];
    }

    /// Number the next cross-file transaction's commit markers will carry.
    pub fn nextTxn(conn: *const Conn) u64 {
        return conn.txn + 1;
    }

    pub fn close(conn: *Conn) void {
        // Unmap the wal-indexes and leave `-alive` under the gate (see
        // openCoordination).
        if (conn.gate_fd >= 0 and !conn.gate_held and !fault.mutated("no-open-gate")) conn.gate_held = lock(conn.gate_fd, c.LOCK_EX);
        if (conn.db) |db| _ = c.sqlite3_close_v2(db);
        conn.db = null;
        if (conn.snap) |page| _ = c.munmap(@ptrCast(page), snap_page_size);
        conn.snap = null;
        for ([_]*c_int{ &conn.writer_fd, &conn.live_fd, &conn.snap_fd, &conn.alive_fd }) |fd| {
            if (fd.* >= 0) _ = c.close(fd.*);
            fd.* = -1;
        }
        conn.releaseGate();
        if (conn.gate_fd >= 0) _ = c.close(conn.gate_fd);
        conn.gate_fd = -1;
        // Give up the members last: until here this handle had them open.
        for (&conn.own_fd) |*fd| {
            if (fd.* >= 0) _ = c.close(fd.*);
            fd.* = -1;
        }
        if (conn.id != 0) {
            @atomicStore(u64, &registry_set[conn.id], 0, .seq_cst);
            @atomicStore(?*Conn, &registry[conn.id], null, .seq_cst);
        }
    }

    fn log(conn: *Conn, comptime fmt: []const u8, args: anytype) void {
        if (!fault.debug) return;
        var pbuf: [1100]u8 = undefined;
        const path = bufPrintZ(&pbuf, "{s}-cwal-debug", .{conn.paths[0]}) catch return;
        const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_APPEND | c.O_CLOEXEC, @as(c_uint, 0o644));
        if (fd < 0) return;
        defer _ = c.close(fd);
        var buf: [512]u8 = undefined;
        const head = std.fmt.bufPrint(&buf, "{d} {s} ev={d} ", .{ c.getpid(), @tagName(conn.role), fault.count() }) catch return;
        const body = std.fmt.bufPrint(buf[head.len..], fmt ++ "\n", args) catch return;
        _ = c.write(fd, &buf, head.len + body.len);
    }

    fn queryIs(conn: *Conn, sql: [:0]const u8, want: []const u8) Error!bool {
        var stmt: ?*c.sqlite3_stmt = null;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_prepare_v2(conn.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK or c.sqlite3_step(stmt) != c.SQLITE_ROW) {
            std.debug.print("sqlite: {s}: {s}\n", .{ sql, c.sqlite3_errmsg(conn.db) });
            return error.Sqlite;
        }
        const text = c.sqlite3_column_text(stmt, 0) orelse return false;
        return std.ascii.eqlIgnoreCase(std.mem.span(text), want);
    }

    fn queryU64(conn: *Conn, sql: [:0]const u8) Error!u64 {
        var stmt: ?*c.sqlite3_stmt = null;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_prepare_v2(conn.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK or c.sqlite3_step(stmt) != c.SQLITE_ROW) {
            std.debug.print("sqlite: {s}: {s}\n", .{ sql, c.sqlite3_errmsg(conn.db) });
            return error.Sqlite;
        }
        return @intCast(c.sqlite3_column_int64(stmt, 0));
    }

    pub fn exec(conn: *Conn, sql: [:0]const u8) Error!void {
        var message: [*c]u8 = null;
        if (c.sqlite3_exec(conn.db, sql.ptr, null, null, &message) != c.SQLITE_OK) {
            if (message != null) {
                std.debug.print("sqlite: {s}: {s}\n", .{ sql, message });
                c.sqlite3_free(message);
            }
            return error.Sqlite;
        }
    }

    fn openLockFile(conn: *Conn, suffix: []const u8) Error!c_int {
        return openSideFile(conn.paths[0], suffix);
    }

    /// `<base>-cwal-<suffix>`, created if missing.
    fn openSideFile(base: []const u8, suffix: []const u8) Error!c_int {
        var buf: [1100]u8 = undefined;
        const path = bufPrintZ(&buf, "{s}-cwal-{s}", .{ base, suffix }) catch return error.Io;
        const creating = fault.powerloss and c.access(path.ptr, c.F_OK) != 0;
        const fd = c.open(path.ptr, c.O_RDWR | c.O_CREAT | c.O_CLOEXEC, @as(c_uint, 0o644));
        if (fd < 0) return error.Io;
        if (creating) overlay.created(path);
        return fd;
    }

    fn lock(fd: c_int, op: c_int) bool {
        while (true) {
            if (c.flock(fd, op) == 0) return true;
            if (c.__errno_location().* != c.EINTR) return false;
        }
    }

    /// `-alive` is held shared by every open handle and taken exclusively
    /// by an opener that finds no other: that opener runs recovery. SQLite
    /// itself rebuilds a member's wal-index from the WAL file, accepting
    /// every valid frame, whenever a process maps it while no other process
    /// has it mapped. Frames a dead writer wrote but never published would
    /// then appear without recovery. The gate makes the two conditions the
    /// same: a handle holds it from before it looks at `-alive` until
    /// SQLite has mapped every member, and while it unmaps them and leaves
    /// `-alive`. So whenever the gate is free, every holder of `-alive` has
    /// every wal-index mapped. A holder can still die (dropping both) while
    /// an opener holds the gate, so the opener checks `-alive` again once
    /// SQLite has mapped every member (aloneAfterMapping): if a holder is
    /// left, it had the wal-indexes mapped throughout, and the opener did
    /// not rebuild one.
    fn openCoordination(conn: *Conn) Error!void {
        conn.gate_fd = try conn.openLockFile("gate");
        if (!fault.mutated("no-open-gate")) {
            if (!lock(conn.gate_fd, c.LOCK_EX)) return error.Io;
            conn.gate_held = true;
        }
        conn.alive_fd = try conn.openLockFile("alive");
        conn.writer_fd = try conn.openLockFile("writer");
        conn.live_fd = try conn.openLockFile("live");
        conn.snap_fd = try conn.openLockFile("snap");
        const snap_size = fileSize(conn.snap_fd) orelse return error.Io;
        if (snap_size < snap_page_size and c.ftruncate(conn.snap_fd, snap_page_size) != 0) return error.Io;
        const mapped = c.mmap(null, snap_page_size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, conn.snap_fd, 0);
        if (mapped == null or @intFromPtr(mapped) == std.math.maxInt(usize)) return error.Io;
        conn.snap = @ptrCast(@alignCast(mapped));

        if (conn.role == .writer and !lock(conn.writer_fd, c.LOCK_EX | c.LOCK_NB)) return error.WriterBusy;
        fault.event("open-alive");
        if (lock(conn.alive_fd, c.LOCK_EX | c.LOCK_NB)) {
            conn.opened_alone = true;
            conn.readShmHeads();
            try conn.recoverAlone();
        } else {
            if (!lock(conn.alive_fd, c.LOCK_SH)) return error.Io;
            conn.log("shared seq={d} cross={d} broken={d}", .{ conn.snap.?.seq, conn.snap.?.cross, conn.snap.?.broken });
            if (!conn.markersReadable(@atomicLoad(u64, &conn.snap.?.seq, .seq_cst))) return error.Broken;
            // Reading a member's -shm opens and closes it, and close(2)
            // drops every POSIX lock this process holds on the file, which
            // would break another connection of this process that has the
            // member open. Member ownership (acquireMembers) leaves only
            // handles of this same set with a member open, and such a handle
            // also rules out the late-alone path (closes take the gate). So
            // read the heads unless this process has another handle of this
            // set.
            if (fault.mutated("heads-process-wide")) {
                if (conn.onlyHandleInProcess()) conn.readShmHeads();
            } else if (!conn.otherHandleOfSet()) conn.readShmHeads();
            test_delay.pause("open-shared");
            if (test_delay.alive_delay_us != 0) _ = c.usleep(test_delay.alive_delay_us);
        }
        if (conn.role == .writer) {
            // A writer that died inside a single-member commit's window left
            // the seqlock odd, and no recovery ran (a cross-file window makes
            // the set unreadable until recovery). Close that window, or every
            // later window would flip its parity.
            const page = conn.snap.?;
            if (@atomicLoad(u64, &page.seq, .seq_cst) & 1 != 0) _ = @atomicRmw(u64, &page.seq, .Add, 1, .seq_cst);
            // The set is readable: announce a live writer (see writerLive).
            if (!lock(conn.live_fd, c.LOCK_EX)) return error.Io;
        }
    }

    /// Read each member's wal-index head for `recover`. On the late-alone
    /// path (see `open`) recovery runs after SQLite has mapped, and so
    /// possibly rebuilt, the wal-indexes, which loses nBackfill; it uses the
    /// heads read here, before `openSqlite`.
    fn readShmHeads(conn: *Conn) void {
        for (0..conn.nmembers) |i| conn.shm_heads[i] = readShmHead(conn.paths[i]);
    }

    /// Whether another handle of this process has this set open (or is
    /// opening it). A hash collision only skips reading the heads.
    fn otherHandleOfSet(conn: *Conn) bool {
        for (1..registry.len) |i| {
            if (i != conn.id and @atomicLoad(u64, &registry_set[i], .seq_cst) == conn.set_hash) return true;
        }
        return false;
    }

    /// The set's identity: every member's resolved path, in order, each
    /// followed by a newline.
    fn identity(conn: *const Conn) Error![]u8 {
        var len: usize = 0;
        for (conn.paths[0..conn.nmembers]) |p| len += p.len + 1;
        const id = allocator.alloc(u8, len) catch return error.Io;
        var at: usize = 0;
        for (conn.paths[0..conn.nmembers]) |p| {
            @memcpy(id[at..][0..p.len], p);
            id[at + p.len] = '\n';
            at += p.len + 1;
        }
        return id;
    }

    /// Never 0, which marks a free registry slot.
    fn setHash(conn: *const Conn) u64 {
        var h = std.hash.Wyhash.init(0);
        for (conn.paths[0..conn.nmembers]) |p| {
            h.update(p);
            h.update("\n");
        }
        return h.final() | 1;
    }

    /// Each member file belongs to one set at a time (REVIEW.md R4).
    /// Recovery, the checkpoint counter and the open/close gate live next to
    /// the main file, so two sets sharing a member, or one main opened with
    /// two member lists, would recover and checkpoint that member under
    /// different locks. Per member, `-cwal-own` is held shared by every
    /// handle of the owning set and records the set's identity. An opener
    /// decides under the member's `-cwal-mgate` (exclusive, held briefly):
    /// if it can lock `-cwal-own` exclusively, no handle owns the member, so
    /// it records its own identity and keeps the lock shared; otherwise it
    /// joins only if the recorded identity is its own, and fails with
    /// MemberOwned if not. The record is written only under the exclusive
    /// lock, which needs every owner gone, so while any handle holds the
    /// lock it names that handle's set. flock(2) locks belong to the open
    /// file description, so handles of one process exclude each other like
    /// handles of different processes. A hard link or bind mount gives one
    /// file two resolved paths, and is not detected.
    fn acquireMembers(conn: *Conn) Error!void {
        if (fault.mutated("no-ownership")) return;
        for (0..conn.nmembers) |i| {
            for (0..i) |j| {
                if (std.mem.eql(u8, conn.paths[i], conn.paths[j])) return error.ProtocolViolation;
            }
        }
        const id = try conn.identity();
        defer allocator.free(id);
        for (0..conn.nmembers) |i| conn.own_fd[i] = try acquireMember(conn.paths[i], id);
    }

    fn acquireMember(path: []const u8, id: []const u8) Error!c_int {
        const gate = try openSideFile(path, "mgate");
        // Closing the descriptor releases the gate.
        defer _ = c.close(gate);
        if (!lock(gate, c.LOCK_EX)) return error.Io;
        const fd = try openSideFile(path, "own");
        errdefer _ = c.close(fd);
        if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) == 0) {
            const wrote = c.pwrite(fd, id.ptr, id.len, 0);
            if (wrote < 0 or @as(usize, @intCast(wrote)) != id.len or c.ftruncate(fd, @intCast(id.len)) != 0) return error.Io;
            // flock(2) converts by unlocking first; openers wait at the gate.
            if (!lock(fd, c.LOCK_SH)) return error.Io;
            return fd;
        }
        if (c.__errno_location().* != c.EWOULDBLOCK) return error.Io;
        // Owned: only by holders of shared locks, since the exclusive lock is
        // taken only under the gate.
        const size = fileSize(fd) orelse return error.Io;
        if (size != id.len) return error.MemberOwned;
        const recorded = allocator.alloc(u8, id.len) catch return error.Io;
        defer allocator.free(recorded);
        const got = c.pread(fd, recorded.ptr, recorded.len, 0);
        if (got < 0 or @as(usize, @intCast(got)) != id.len) return error.Io;
        if (!std.mem.eql(u8, recorded, id)) return error.MemberOwned;
        if (!lock(fd, c.LOCK_SH | c.LOCK_NB)) return error.Io;
        return fd;
    }

    fn onlyHandleInProcess(conn: *Conn) bool {
        for (1..registry.len) |i| {
            if (i != conn.id and @atomicLoad(?*Conn, &registry[i], .seq_cst) != null) return false;
        }
        return true;
    }

    /// With `-alive` held exclusively (no other handle has the set open):
    /// repair an interrupted commit before SQLite reads any WAL file, then
    /// share `-alive`.
    fn recoverAlone(conn: *Conn) Error!void {
        conn.log("alone seq={d} cross={d} broken={d}", .{ conn.snap.?.seq, conn.snap.?.cross, conn.snap.?.broken });
        try conn.recover();
        // A writer that died inside a window left the seqlock odd.
        @atomicStore(u64, &conn.snap.?.seq, 0, .seq_cst);
        @atomicStore(u32, &conn.snap.?.cross, 0, .seq_cst);
        @atomicStore(u32, &conn.snap.?.broken, 0, .seq_cst);
        if (!lock(conn.alive_fd, c.LOCK_SH)) return error.Io;
    }

    /// Repair an interrupted cross-file commit. Runs only while this handle
    /// is the only one with the set open, before SQLite opens any member.
    /// Only the newest cross-file transaction can be torn, because the
    /// writer starts the next commit only after every member of this one is
    /// durable. If a member it wrote lacks its marker, remove it from the
    /// members that have it; it is their last commit. Idempotent, so a crash
    /// during recovery leaves it to be run again.
    fn recover(conn: *Conn) Error!void {
        fault.event("recover-begin");
        var markers: [max_members]Marker = @splat(.{});
        var newest: Marker = .{};
        for (0..conn.nmembers) |i| {
            markers[i] = try readMarker(conn.paths[i]);
            if (markers[i].txn > newest.txn) newest = markers[i];
            conn.log("recover member {d} txn={d} mask={d}", .{ i, markers[i].txn, markers[i].mask });
        }
        // Marker numbers are unique, so every member with the newest number
        // must carry the same member set and belong to it.
        if (newest.txn != 0 and newest.mask >> @intCast(conn.nmembers - 1) >> 1 != 0) return error.ProtocolViolation;
        var torn = false;
        for (0..conn.nmembers) |i| {
            const bit = @as(u32, 1) << @intCast(i);
            if (newest.txn != 0 and markers[i].txn == newest.txn and (markers[i].mask != newest.mask or newest.mask & bit == 0)) return error.ProtocolViolation;
            if (newest.mask & bit != 0 and markers[i].txn != newest.txn) torn = true;
        }
        if (torn and !fault.mutated("no-marker-rollback")) {
            last_recovery = "rollback";
            // Check every member before truncating any, so that a refusal
            // leaves the set as the crash left it.
            var fds: [max_members]c_int = @splat(-1);
            defer for (fds) |fd| {
                if (fd >= 0) _ = c.close(fd);
            };
            var keep: [max_members]i64 = @splat(0);
            for (0..conn.nmembers) |i| {
                if (markers[i].txn != newest.txn) continue;
                var buf: [1100]u8 = undefined;
                const wal = bufPrintZ(&buf, "{s}-wal", .{conn.paths[i]}) catch return error.Io;
                fds[i] = c.open(wal.ptr, c.O_RDWR | c.O_CLOEXEC);
                if (fds[i] < 0) return error.ProtocolViolation;
                const last = walLastCommit(fds[i], markers[i].root) orelse return error.ProtocolViolation;
                // The torn commit cannot have been checkpointed: the writer
                // checkpoints only between commits. A connection outside the
                // protocol may have checkpointed it, and may then have written
                // a commit of its own, which the marker update is not part of.
                if (!fault.mutated("no-backfill-check") and (!last.writes_page or backfilledPast(conn.shm_heads[i], fds[i], last.start))) {
                    conn.log("recover member {d}: torn commit already checkpointed", .{i});
                    return error.ProtocolViolation;
                }
                keep[i] = last.start;
            }
            for (0..conn.nmembers) |i| {
                if (fds[i] < 0) continue;
                var buf: [1100]u8 = undefined;
                const wal = bufPrintZ(&buf, "{s}-wal", .{conn.paths[i]}) catch return error.Io;
                try truncateDurably(fds[i], wal, keep[i], "recover");
            }
        }
        // readMarker left wal-index files built before the truncation.
        for (0..conn.nmembers) |i| {
            var buf: [1100]u8 = undefined;
            const shm = bufPrintZ(&buf, "{s}-shm", .{conn.paths[i]}) catch return error.Io;
            fault.event("recover-unlink-shm");
            _ = c.unlink(shm.ptr);
        }
    }

    /// Whether the members' published states form one committed state. A
    /// writer that died inside a cross-file window may have published some
    /// members only, and one that rolled back after publishing marked the
    /// set broken; either needs recovery. While the writer is alive, readers
    /// see the window and use snapshots.
    fn markersReadable(conn: *Conn, seq: u64) bool {
        const page = conn.snap.?;
        if (@atomicLoad(u32, &page.broken, .seq_cst) != 0) return false;
        if (seq & 1 == 0 or @atomicLoad(u32, &page.cross, .seq_cst) == 0 or fault.mutated("no-cross-flag")) return true;
        return conn.role == .reader and conn.writerLive();
    }

    /// The writer holds `-live` from the end of a successful open (set
    /// readable) until it closes or dies. A writer that finds an interrupted
    /// cross-file window never takes it, so it always belongs to the writer
    /// of the current window.
    fn writerLive(conn: *Conn) bool {
        if (c.flock(conn.live_fd, c.LOCK_SH | c.LOCK_NB) == 0) {
            _ = c.flock(conn.live_fd, c.LOCK_UN);
            return false;
        }
        return true;
    }

    /// Whether this handle may copy WAL frames into a database file now.
    fn checkpointAllowed(conn: *Conn) bool {
        fault.event("checkpoint-check");
        const broken = @atomicLoad(u32, &conn.snap.?.broken, .seq_cst) != 0;
        const allowed = conn.role == .writer and !conn.in_commit and !conn.window_open and !broken;
        if (!allowed) conn.stats.checkpoint_denied += 1;
        return allowed;
    }

    /// A process killed while holding an exclusive checkpoint lock leaves
    /// the counter's active count raised, and every later snapshot open
    /// would take the real lock. A live process is counted exactly while it
    /// holds that lock (see ioShmLock), so while this writer holds every
    /// member's checkpoint lock, every counted checkpointer is dead: clear
    /// them. If a live process keeps a lock past the deadline, the count
    /// stays, which only costs readers the real lock.
    fn resetCheckpointers(conn: *Conn) void {
        if (fault.mutated("no-ckpt-reset")) return;
        var held: [max_members]bool = @splat(false);
        defer for (0..conn.nmembers) |m| {
            if (held[m]) {
                const f = conn.member_db[m].?;
                _ = realMethods(f).xShmLock.?(f.real, wal_ckpt_lock, 1, c.SQLITE_SHM_UNLOCK | c.SQLITE_SHM_EXCLUSIVE);
            }
        };
        const deadline = monotonicNs() + 1_000_000_000;
        for (0..conn.nmembers) |m| {
            const f = conn.member_db[m] orelse return;
            while (realMethods(f).xShmLock.?(f.real, wal_ckpt_lock, 1, c.SQLITE_SHM_LOCK | c.SQLITE_SHM_EXCLUSIVE) != c.SQLITE_OK) {
                conn.stats.reset_waits += 1;
                if (monotonicNs() > deadline) return;
                _ = c.usleep(100);
            }
            held[m] = true;
        }
        test_delay.point("reset-held");
        conn.log("checkpoint counter reset waits={d}", .{conn.stats.reset_waits});
        fault.event("ckpt-reset");
        _ = @atomicRmw(u64, &conn.snap.?.ckpt, .And, ~(ckpt_started - 1), .seq_cst);
    }

    /// A writer killed after writing a member's frames but before publishing
    /// them leaves frames past that member's mxFrame. While other handles
    /// keep the set open no recovery runs, and the next writer may never
    /// overwrite them (it need not write that member), so SQLite's WAL
    /// recovery would accept them once every handle has closed, reviving a
    /// commit out of order or one that recovery should have removed. Drop
    /// them before this writer commits anything, holding each member's WAL
    /// write lock: only a writer appends frames (and a wal-index recovery,
    /// which also takes that lock), and readers never read past mxFrame.
    fn discardUnpublished(conn: *Conn) Error!void {
        if (fault.mutated("no-discard-unpublished")) return;
        for (0..conn.nmembers) |m| {
            const f = conn.member_db[m] orelse return error.ProtocolViolation;
            const deadline = monotonicNs() + 2_000_000_000;
            while (realMethods(f).xShmLock.?(f.real, wal_write_lock, 1, c.SQLITE_SHM_LOCK | c.SQLITE_SHM_EXCLUSIVE) != c.SQLITE_OK) {
                if (monotonicNs() > deadline) return error.Sqlite;
                _ = c.usleep(100);
            }
            defer _ = realMethods(f).xShmLock.?(f.real, wal_write_lock, 1, c.SQLITE_SHM_UNLOCK | c.SQLITE_SHM_EXCLUSIVE);
            try conn.truncateUnpublished(m);
        }
    }

    fn truncateUnpublished(conn: *Conn, m: usize) Error!void {
        var hdr: [48]u8 = undefined;
        if (!conn.readHeader(m, &hdr)) return error.ProtocolViolation;
        var buf: [1100]u8 = undefined;
        const wal = bufPrintZ(&buf, "{s}-wal", .{conn.paths[m]}) catch return error.Io;
        const fd = c.open(wal.ptr, c.O_RDWR | c.O_CLOEXEC);
        if (fd < 0) return;
        defer _ = c.close(fd);
        // wal-index header (native byte order): szPage u16 @14, mxFrame
        // u32 @16, salts @32 (copied from the WAL header's bytes 16..24).
        const mx = std.mem.readInt(u32, hdr[16..20], native_endian);
        var keep: i64 = 0;
        if (mx != 0) {
            const sz: u32 = std.mem.readInt(u16, hdr[14..16], native_endian);
            const page_size = (sz & 0xfe00) + ((sz & 1) << 16);
            var file_hdr: [wal_header_size]u8 = undefined;
            if (c.pread(fd, &file_hdr, file_hdr.len, 0) != file_hdr.len or !std.mem.eql(u8, file_hdr[16..24], hdr[32..40])) return error.ProtocolViolation;
            keep = wal_header_size + @as(i64, mx) * (wal_frame_header_size + page_size);
        }
        const size = fileSize(fd) orelse return error.Io;
        conn.log("discard member {d} mx={d} size={d} keep={d}", .{ m, mx, size, keep });
        if (size <= keep) return;
        try truncateDurably(fd, wal, keep, "discard");
        conn.stats.discarded_bytes += @intCast(size - keep);
    }

    /// Copy a member's wal-index header (the first of its two copies).
    fn readHeader(conn: *Conn, member: usize, out: *[48]u8) bool {
        const f = conn.member_db[member] orelse return false;
        var region: ?*volatile anyopaque = null;
        if (realMethods(f).xShmMap.?(f.real, 0, shm_region_size, 0, &region) != c.SQLITE_OK or region == null) return false;
        const h: [*]volatile u8 = @ptrCast(region.?);
        if (h[12] != 1) return false; // isInit
        for (out, 0..) |*b, i| b.* = h[i];
        return true;
    }

    /// Returns false for a commit frame written outside a commit the hook
    /// approved: a path that bypasses the commit hook (VACUUM) would publish
    /// it without a window, and from a reader handle.
    fn observeWalWrite(conn: *Conn, bytes: []const u8) bool {
        if (conn.mode != .cwal) return true;
        if (bytes.len != wal_frame_header_size or std.mem.readInt(u32, bytes[4..8], .big) == 0) return true;
        if (!conn.in_commit) {
            conn.log("refused commit frame outside a commit", .{});
            return fault.mutated("no-frame-guard");
        }
        conn.any_commit_frame = true;
        return true;
    }

    /// End the publication window: make the seqlock even again.
    fn closeWindow(conn: *Conn) void {
        fault.event("gate-release");
        _ = @atomicRmw(u64, &conn.snap.?.seq, .Add, 1, .seq_cst);
        conn.window_open = false;
    }

    fn commitHook(arg: ?*anyopaque) callconv(.c) c_int {
        const conn: *Conn = @ptrCast(@alignCast(arg.?));
        if (conn.role != .writer) return 1;
        fault.event("commit-hook");
        conn.in_commit = true;
        conn.any_commit_frame = false;
        var written: u32 = 0;
        for (0..conn.nmembers) |m| written += @intFromBool(conn.write_locked[m]);
        conn.cross = written >= 2;
        conn.log("commit hook written={d}", .{written});
        const marked = conn.marker_pending;
        conn.marker_pending = false;
        if (@atomicLoad(u32, &conn.snap.?.broken, .seq_cst) != 0) return 1;
        // Only TEMP was written: no member commits, so no phase two or
        // rollback hook would end this commit.
        if (written == 0) {
            conn.in_commit = false;
            return 0;
        }
        // A cross-file commit without markers could not be recovered.
        if (conn.cross and !marked and !fault.mutated("no-markers")) {
            conn.violation = true;
            return 1;
        }
        return 0;
    }

    /// Returns false if the commit must fail: its window could not open.
    fn startPublication(conn: *Conn) bool {
        if (conn.mode != .cwal or !conn.in_commit or conn.window_open or fault.mutated("no-gate")) return true;
        // Single-member commits open the window too: otherwise a reader
        // pinning members in order could see a later solo commit on one
        // member but miss an earlier one on another.
        if (!conn.cross and fault.mutated("no-solo-window")) return true;
        // No member has published yet: their current headers are the last
        // committed state of the set.
        const page = conn.snap.?;
        for (0..conn.nmembers) |m| {
            if (!conn.readHeader(m, &page.hdr[m])) {
                conn.log("window not opened: no header for member {d}", .{m});
                return false;
            }
        }
        conn.log("window open cross={}", .{conn.cross});
        @atomicStore(u32, &page.cross, @intFromBool(conn.cross), .seq_cst);
        fault.event("gate-acquire");
        _ = @atomicRmw(u64, &page.seq, .Add, 1, .seq_cst);
        conn.window_open = true;
        if (test_delay.window_delay_us != 0) _ = c.usleep(test_delay.window_delay_us);
        return true;
    }

    fn commitPhaseTwo(conn: *Conn) void {
        if (conn.mode != .cwal or !conn.in_commit) return;
        // SQLite runs phase one (WAL frames, sync, wal-index update) for every
        // member before phase two of any, so every member has published and
        // every commit frame is durable.
        fault.event("phase-two");
        conn.log("phase two window_open={}", .{conn.window_open});
        if (conn.window_open) conn.closeWindow();
        conn.in_commit = false;
        conn.stats.commits += 1;
    }

    fn rollbackHook(arg: ?*anyopaque) callconv(.c) void {
        const conn: *Conn = @ptrCast(@alignCast(arg.?));
        if (!conn.in_commit) return;
        // A commit frame already published on one member cannot be taken
        // back while other handles may read it: mark the set broken before
        // the window ends.
        if (conn.cross and conn.any_commit_frame) {
            @atomicStore(u32, &conn.snap.?.broken, 1, .seq_cst);
        }
        if (conn.window_open) conn.closeWindow();
        conn.in_commit = false;
    }

    /// Commit the open write transaction. A transaction that writes two or
    /// more members first records its number and member set (its commit
    /// marker) in each of them.
    pub fn commit(conn: *Conn) Error!void {
        if (conn.mode == .cwal and !fault.mutated("no-markers")) {
            var mask: u32 = 0;
            for (0..conn.nmembers) |m| {
                if (conn.write_locked[m]) mask |= @as(u32, 1) << @intCast(m);
            }
            if (@popCount(mask) >= 2) {
                const t = conn.txn + 1;
                conn.internal = true;
                defer conn.internal = false;
                for (0..conn.nmembers) |m| {
                    if (mask & (@as(u32, 1) << @intCast(m)) == 0) continue;
                    var buf: [128]u8 = undefined;
                    try conn.exec(bufPrintZ(&buf, "update {s}.cwal_marker set txn = {d}, mask = {d} where k = 0", .{ schemaName(m), t, mask }) catch return error.Io);
                }
                conn.marker_pending = true;
                defer conn.marker_pending = false;
                // Used even if the commit fails: never reuse a number.
                conn.txn = t;
                try conn.exec("commit");
                return;
            }
        }
        try conn.exec("commit");
    }

    /// Run one statement as its own transaction. A statement that writes
    /// several members cannot autocommit (it would carry no markers), so it
    /// runs inside an explicit transaction.
    pub fn autocommit(conn: *Conn, sql: [:0]const u8) Error!void {
        if (conn.mode != .cwal) return conn.exec(sql);
        try conn.exec("begin");
        conn.exec(sql) catch |err| {
            conn.rollbackOpen();
            return err;
        };
        conn.commit() catch |err| {
            conn.rollbackOpen();
            return err;
        };
    }

    /// Roll back the transaction, if a failed statement or commit has not
    /// already ended it (SQLite rolls back on I/O errors and full disks).
    pub fn rollbackOpen(conn: *Conn) void {
        if (c.sqlite3_get_autocommit(conn.db) == 0) conn.exec("rollback") catch {};
    }

    /// Begin a read transaction that sees every member at one point between
    /// commits. `gap_us` waits between pinning members, to widen the window a
    /// mixed view needs.
    pub fn beginRead(conn: *Conn, gap_us: u32) Error!void {
        if (conn.mode == .cwal) return conn.beginSnapshotRead(gap_us);
        try conn.exec("begin");
        try conn.pinMembers(gap_us);
    }

    /// Start the read transaction on every member, in order.
    fn pinMembers(conn: *Conn, gap_us: u32) Error!void {
        for (0..conn.nmembers) |i| {
            if (i != 0 and gap_us != 0) _ = c.usleep(gap_us);
            var buf: [96]u8 = undefined;
            const sql = bufPrintZ(&buf, "select count(*) from {s}.sqlite_schema", .{schemaName(i)}) catch return error.Io;
            conn.exec(sql) catch |err| {
                conn.exec("rollback") catch {};
                return err;
            };
        }
    }

    /// SQLite takes a shared checkpoint lock around each snapshot open (two
    /// fcntl calls per member and read) only so that no checkpoint can
    /// choose to copy frames past the snapshot and record that choice
    /// (nBackfillAttempted) on either side of the open's check. Every
    /// exclusive lock on that byte goes through this VFS and moves the
    /// checkpoint counter first, so the reader skips the real lock and
    /// validates instead: no checkpointer active when the lock is "taken",
    /// none started by the time it is "released". Either a checkpointer
    /// finished before (the reader sees its nBackfillAttempted), or it
    /// starts after the reader holds its read mark (and stops below it).
    /// Otherwise the open is retried. Returns false to take the real lock.
    fn ckptLockShared(conn: *Conn, member: u8, take: bool) bool {
        const page = conn.snap.?;
        if (take) {
            test_delay.point("open-take");
            const w = @atomicLoad(u64, &page.ckpt, .seq_cst);
            if (fault.mutated("no-ckpt-skip") or @as(u32, @truncate(w)) != 0) {
                conn.stats.ckpt_fallbacks += 1;
                return false;
            }
            conn.ckpt_skipped[member] = true;
            conn.ckpt_start[member] = @intCast(w >> 32);
            if (test_delay.ckpt_open_delay_us != 0) _ = c.usleep(test_delay.ckpt_open_delay_us);
            return true;
        }
        if (!conn.ckpt_skipped[member]) return false;
        conn.ckpt_skipped[member] = false;
        test_delay.point("open-release");
        // Full barrier: the read mark SQLite stored during the open must be
        // visible before the counter is loaded (see ioShmLock). SQLite's
        // walTryBeginRead also issues one after setting the mark.
        if (conn.member_db[member]) |f| realMethods(f).xShmBarrier.?(f.real);
        const w = @atomicLoad(u64, &page.ckpt, .seq_cst);
        if (@as(u32, @intCast(w >> 32)) != conn.ckpt_start[member]) {
            conn.stats.ckpt_races += 1;
            if (!fault.mutated("no-ckpt-validate")) conn.ckpt_race = true;
        }
        return true;
    }

    /// Test check, during a read: no checkpoint has recorded an intent to
    /// copy frames past a member's snapshot (nBackfillAttempted, in the
    /// wal-index after the two headers and nBackfill, the read marks and the
    /// lock bytes). That is what SQLite's checkpoint lock guarantees for a
    /// snapshot open; afterwards the reader's read mark does.
    pub fn snapshotIntact(conn: *Conn) bool {
        if (!conn.snapshot_open) return true;
        for (0..conn.nmembers) |m| {
            const f = conn.member_db[m] orelse continue;
            const shm: [*]u8 = @ptrCast(f.shm0 orelse continue);
            const attempted = @atomicLoad(u32, @as(*u32, @ptrCast(@alignCast(shm + 128))), .seq_cst);
            if (attempted > conn.snapshot_mx[m]) return false;
        }
        return true;
    }

    /// Seqlock read. Outside a publication window, pin the members normally
    /// and retry if a window started meanwhile. Inside one, open each member
    /// at the header the writer saved before any member published.
    fn beginSnapshotRead(conn: *Conn, gap_us: u32) Error!void {
        const page = conn.snap.?;
        conn.snapshot_open = false;
        while (true) {
            const s1 = @atomicLoad(u64, &page.seq, .seq_cst);
            // Check after reading the sequence: a writer that rolls back
            // after publishing marks the set broken before the window ends.
            if (!conn.markersReadable(s1)) return error.Broken;
            if (s1 & 1 == 0) {
                try conn.exec("begin");
                try conn.pinMembers(gap_us);
                if (fault.mutated("no-seq-check") or @atomicLoad(u64, &page.seq, .seq_cst) == s1) return;
                conn.exec("rollback") catch {};
                conn.stats.seq_retries += 1;
                continue;
            }
            var hdrs: [max_members][48]u8 = undefined;
            const shared: *volatile [max_members][48]u8 = &page.hdr;
            for (0..conn.nmembers) |m| hdrs[m] = shared[m];
            // A read-modify-write orders the copy before the recheck.
            if (@atomicRmw(u64, &page.seq, .Add, 0, .seq_cst) != s1) {
                conn.stats.seq_retries += 1;
                continue;
            }
            try conn.exec("begin");
            if (fault.mutated("no-snapshot-open")) {
                try conn.pinMembers(gap_us);
                return;
            }
            var opened = true;
            conn.opening_seq = s1;
            conn.ckpt_race = false;
            for (0..conn.nmembers) |m| {
                if (m != 0 and gap_us != 0) _ = c.usleep(gap_us);
                var snapshot: c.sqlite3_snapshot = .{ .hidden = hdrs[m] };
                if (c.sqlite3_snapshot_open(conn.db, schemaName(m).ptr, &snapshot) != c.SQLITE_OK) {
                    opened = false;
                    break;
                }
            }
            conn.opening_seq = 0;
            conn.ckpt_skipped = @splat(false);
            if (conn.ckpt_race) {
                conn.exec("rollback") catch {};
                continue;
            }
            if (opened) {
                for (0..conn.nmembers) |m| conn.snapshot_mx[m] = std.mem.readInt(u32, hdrs[m][16..20], native_endian);
                conn.snapshot_open = true;
                conn.stats.snapshot_reads += 1;
                return;
            }
            // The saved state is no longer available (rare: SQLite could not
            // keep a read mark at it). Wait for the window to end.
            conn.exec("rollback") catch {};
            conn.stats.snapshot_waits += 1;
            const start = monotonicNs();
            defer conn.stats.window_wait_ns += monotonicNs() - start;
            while (@atomicLoad(u64, &page.seq, .seq_cst) == s1) {
                if (!conn.writerLive()) return error.Broken;
                _ = c.usleep(50);
            }
        }
    }
};

/// Outcome of the last recovery this process ran: "none" or "rollback".
pub var last_recovery: []const u8 = "none";

pub fn monotonicNs() u64 {
    // struct timespec as {tv_sec, tv_nsec} (64-bit Linux): musl's has
    // padding bitfields that translate-c cannot represent.
    var ts: [2]c_long = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, @ptrCast(&ts));
    return @as(u64, @intCast(ts[0])) * 1_000_000_000 + @as(u64, @intCast(ts[1]));
}

/// A file's size without struct stat (opaque under musl's translate-c).
/// Moves the file offset; all I/O on these descriptors is positional.
pub fn fileSize(fd: c_int) ?i64 {
    const size = c.lseek(fd, 0, c.SEEK_END);
    return if (size < 0) null else size;
}
