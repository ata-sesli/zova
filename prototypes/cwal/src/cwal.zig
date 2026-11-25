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

pub const max_members = 4;
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
    /// checkpointers left by dead processes).
    pub var mutate: []const u8 = "";
    pub var syncs: u64 = 0;

    pub fn init() void {
        crash_at = envU64("CWAL_CRASH_AT") orelse 0;
        powerloss = (envU64("CWAL_POWERLOSS") orelse 0) != 0;
        trace = (envU64("CWAL_TRACE") orelse 0) != 0;
        // With CWAL_CRASH_TAG, CWAL_CRASH_AT counts only events with that tag.
        if (c.getenv("CWAL_CRASH_TAG")) |tag| crash_tag = std.mem.span(tag);
        if (c.getenv("CWAL_MUTATE")) |m| mutate = std.mem.span(m);
        rng ^= (envU64("CWAL_SEED") orelse 1) *% 0x2545f4914f6cdd1d;
    }

    pub fn mutated(name: []const u8) bool {
        return std.mem.eql(u8, mutate, name);
    }

    pub fn count() u64 {
        return @atomicLoad(u64, &events, .seq_cst);
    }

    pub fn event(tag: []const u8) void {
        const n = @atomicRmw(u64, &events, .Add, 1, .seq_cst) + 1;
        if (trace) std.debug.print("event {d} {s}\n", .{ n, tag });
        if (crash_tag) |want| {
            if (std.mem.eql(u8, tag, want) and @atomicRmw(u64, &tagged, .Add, 1, .seq_cst) + 1 == crash_at) crash();
        } else if (crash_at != 0 and n == crash_at) crash();
    }

    pub fn random() u64 {
        rng ^= rng << 13;
        rng ^= rng >> 7;
        rng ^= rng << 17;
        return rng;
    }

    pub fn crash() noreturn {
        if (powerloss) overlay.persistRandomSubset();
        _ = c.kill(c.getpid(), c.SIGKILL);
        while (true) _ = c.pause();
    }
};

/// Power-loss model. While enabled, writes stay in memory until the file is
/// synced, as if they sat in a volatile cache. A crash persists a random
/// subset of them, some torn at 512-byte granularity. Single-threaded use
/// only: power-loss runs use one writer process.
const overlay = struct {
    const Pending = struct { offset: i64, data: []u8 };
    const Slot = struct { path: [:0]u8, pending: std.ArrayList(Pending) = .empty };
    var slots: std.ArrayList(Slot) = .empty;
    const allocator = std.heap.c_allocator;

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

    fn maxEnd(slot: *Slot) i64 {
        var end: i64 = 0;
        for (slot.pending.items) |p| end = @max(end, p.offset + @as(i64, @intCast(p.data.len)));
        return end;
    }

    fn applyTo(slot: *Slot, buffer: []u8, offset: i64) void {
        for (slot.pending.items) |p| {
            const start = @max(offset, p.offset);
            const end = @min(offset + @as(i64, @intCast(buffer.len)), p.offset + @as(i64, @intCast(p.data.len)));
            if (start >= end) continue;
            const dst = buffer[@intCast(start - offset)..@intCast(end - offset)];
            @memcpy(dst, p.data[@intCast(start - p.offset)..@intCast(end - p.offset)]);
        }
    }

    fn writeRaw(path: [:0]const u8, offset: i64, bytes: []const u8) void {
        const fd = c.open(path.ptr, c.O_WRONLY | c.O_CLOEXEC);
        if (fd < 0) return;
        defer _ = c.close(fd);
        _ = c.pwrite(fd, bytes.ptr, bytes.len, offset);
    }

    fn flush(path: []const u8) void {
        const slot = find(path, false) orelse return;
        for (slot.pending.items) |p| {
            writeRaw(slot.path, p.offset, p.data);
            allocator.free(p.data);
        }
        slot.pending.clearRetainingCapacity();
    }

    fn discard(path: []const u8) void {
        const slot = find(path, false) orelse return;
        for (slot.pending.items) |p| allocator.free(p.data);
        slot.pending.clearRetainingCapacity();
    }

    fn flushAll() void {
        for (slots.items) |*slot| flush(slot.path);
    }

    fn persistRandomSubset() void {
        for (slots.items) |*slot| {
            for (slot.pending.items) |p| {
                switch (fault.random() % 3) {
                    0 => {},
                    1 => writeRaw(slot.path, p.offset, p.data),
                    else => {
                        const sectors = (p.data.len + 511) / 512;
                        const keep = @min(p.data.len, (fault.random() % (sectors + 1)) * 512);
                        writeRaw(slot.path, p.offset, p.data[0..keep]);
                    },
                }
            }
        }
    }
};

/// Persist writes held by the power-loss model. Call before a normal exit.
pub fn flushPending() void {
    if (fault.powerloss) overlay.flushAll();
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
};

pub fn register() void {
    fault.init();
    test_delay.window_delay_us = @intCast(envU64("CWAL_WINDOW_DELAY_US") orelse 0);
    test_delay.ckpt_open_delay_us = @intCast(envU64("CWAL_CKPT_OPEN_DELAY_US") orelse 0);
    test_delay.ckpt_scan_delay_us = @intCast(envU64("CWAL_CKPT_SCAN_DELAY_US") orelse 0);
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
    if (name != null and f.kind != .other) {
        if (c.sqlite3_uri_parameter(name, "cwal")) |id| f.conn_id = std.fmt.parseInt(u32, std.mem.span(id), 10) catch 0;
        if (c.sqlite3_uri_parameter(name, "cwm")) |m| f.member = std.fmt.parseInt(u8, std.mem.span(m), 10) catch 0;
    }
    const rc = unix_vfs.*.xOpen.?(unix_vfs, name, f.real, flags, out_flags);
    if (rc != c.SQLITE_OK) {
        if (f.real.*.pMethods != null) _ = f.real.*.pMethods.*.xClose.?(f.real);
        return rc;
    }
    f.base.pMethods = &io_methods;
    if (f.kind == .main_db) {
        if (connFor(f)) |conn| conn.member_db[f.member] = f;
    }
    return rc;
}

fn vfsDelete(vfs: [*c]c.sqlite3_vfs, name: [*c]const u8, sync_dir: c_int) callconv(.c) c_int {
    _ = vfs;
    fault.event("delete");
    if (fault.powerloss) overlay.discard(std.mem.span(name));
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
    if (!fault.powerloss) return realMethods(f).xRead.?(f.real, buffer, amount, offset);
    const slot = overlay.find(pathSlice(f), false) orelse return realMethods(f).xRead.?(f.real, buffer, amount, offset);
    if (slot.pending.items.len == 0) return realMethods(f).xRead.?(f.real, buffer, amount, offset);
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
    fault.event(switch (f.kind) {
        .main_db => "write-db",
        .wal => "write-wal",
        .other => "write-other",
    });
    const bytes = @as([*]const u8, @ptrCast(buffer.?))[0..@intCast(amount)];
    if (f.kind == .wal) {
        if (connFor(f)) |conn| conn.observeWalWrite(bytes);
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
    // Model truncation as ordered after earlier writes to the file.
    if (fault.powerloss) overlay.flush(pathSlice(f));
    return realMethods(f).xTruncate.?(f.real, size);
}

fn ioSync(file: [*c]c.sqlite3_file, flags: c_int) callconv(.c) c_int {
    const f = asFile(file);
    fault.event("sync");
    if (fault.powerloss) overlay.flush(pathSlice(f));
    _ = @atomicRmw(u64, &fault.syncs, .Add, 1, .seq_cst);
    const rc = realMethods(f).xSync.?(f.real, flags);
    fault.event("sync-done");
    if (f.kind == .wal) {
        // With synchronous=FULL, SQLite syncs a member's WAL after writing
        // its commit frame and before publishing it in the wal-index. The
        // first such sync of a commit starts the publication window.
        if (connFor(f)) |conn| conn.startPublication();
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
            cn.ckpt_ex[f.member] = false;
            _ = @atomicRmw(u64, &cn.snap.?.ckpt, .Sub, 1, .seq_cst);
        }
        if (cn.ckpt_ex[f.member] and offset == wal_read_lock0 and n == 1 and flags == c.SQLITE_SHM_LOCK | c.SQLITE_SHM_EXCLUSIVE and test_delay.ckpt_scan_delay_us != 0) {
            _ = c.usleep(test_delay.ckpt_scan_delay_us);
        }
    }
    const rc = realMethods(f).xShmLock.?(f.real, offset, n, flags);
    if (conn) |cn| {
        if (cn.mode == .cwal and ckpt_exclusive and flags & c.SQLITE_SHM_LOCK != 0 and rc == c.SQLITE_OK) {
            // Announce the checkpointer before SQLite, holding the lock, can
            // look at read marks or write anything.
            _ = @atomicRmw(u64, &cn.snap.?.ckpt, .Add, ckpt_started + 1, .seq_cst);
            cn.ckpt_ex[f.member] = true;
            fault.event("ckpt-locked");
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

/// Offset at which the last commit in the WAL behind `fd` starts: the end of
/// the commit before it, or the end of the header if it is the only one.
/// Frames are accepted as SQLite's WAL recovery accepts them: the header is
/// valid, and each frame carries the header salts and continues the checksum
/// chain. Null if the WAL holds no valid commit.
fn walLastCommitStart(fd: c_int) ?i64 {
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
    var offset: i64 = wal_header_size;
    while (true) : (offset += @intCast(frame_size)) {
        if (c.pread(fd, frame.ptr, frame_size, offset) != frame_size) break;
        if (!std.mem.eql(u8, frame[8..16], header[16..24])) break;
        if (std.mem.readInt(u32, frame[0..4], .big) == 0) break;
        walChecksum(big, frame[0..8], &s);
        walChecksum(big, frame[wal_frame_header_size..], &s);
        if (s[0] != std.mem.readInt(u32, frame[16..20], .big) or s[1] != std.mem.readInt(u32, frame[20..24], .big)) break;
        if (std.mem.readInt(u32, frame[4..8], .big) != 0) {
            if (last) |end| prev = end;
            last = offset + @as(i64, @intCast(frame_size));
        }
    }
    return if (last != null) prev else null;
}

const Marker = struct { txn: u64 = 0, mask: u32 = 0 };

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
    if (c.sqlite3_prepare_v2(db, "select txn, mask from cwal_marker where k = 0", -1, &stmt, null) != c.SQLITE_OK) return .{};
    defer _ = c.sqlite3_finalize(stmt);
    return switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => .{ .txn = @intCast(c.sqlite3_column_int64(stmt, 0)), .mask = @intCast(c.sqlite3_column_int64(stmt, 1)) },
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

pub const Error = error{ Sqlite, Broken, WriterBusy, Io, ProtocolViolation };

pub const Options = struct {
    mode: Mode,
    role: Role,
    synchronous: [:0]const u8 = "FULL",
    cache_pages: i32 = 0,
    busy_timeout_ms: c_int = 10_000,
};

var registry: [256]?*Conn = @splat(null);

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
        for (paths, 0..) |p, i| conn.paths[i] = allocator.dupeSentinel(u8, p, 0) catch return error.Io;
        const id = claimSlot(conn) orelse return error.Io;
        conn.id = id;
        errdefer conn.close();

        if (options.mode == .cwal) {
            // The publication window starts at a commit-time WAL sync, which
            // SQLite issues only with synchronous=FULL or EXTRA.
            if (!std.ascii.eqlIgnoreCase(options.synchronous, "FULL") and !std.ascii.eqlIgnoreCase(options.synchronous, "EXTRA")) return error.ProtocolViolation;
            try conn.openCoordination();
        }

        var uri_buf: [1024]u8 = undefined;
        const main_uri = bufPrintZ(&uri_buf, "file:{s}?cwal={d}&cwm=0", .{ conn.paths[0], id }) catch return error.Io;
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(main_uri.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_URI, "cwal") != c.SQLITE_OK) {
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
            // Read every member once, so each pager has its WAL open (which
            // sqlite3_snapshot_open requires) and its wal-index mapped.
            for (0..paths.len) |i| {
                var sql_buf: [96]u8 = undefined;
                try conn.exec(bufPrintZ(&sql_buf, "select count(*) from {s}.sqlite_schema", .{schemaName(i)}) catch return error.Io);
            }
            _ = c.sqlite3_commit_hook(db, &commitHook, conn);
            _ = c.sqlite3_rollback_hook(db, &rollbackHook, conn);
            if (options.role == .writer) {
                conn.resetCheckpointers();
                // One single-member commit per statement.
                for (0..paths.len) |i| {
                    var sql_buf: [160]u8 = undefined;
                    const schema = schemaName(i);
                    try conn.exec(bufPrintZ(&sql_buf, "create table if not exists {s}.cwal_marker(k integer primary key, txn integer not null, mask integer not null)", .{schema}) catch return error.Io);
                    try conn.exec(bufPrintZ(&sql_buf, "insert or ignore into {s}.cwal_marker values (0, 0, 0)", .{schema}) catch return error.Io);
                    var stmt: ?*c.sqlite3_stmt = null;
                    const q = bufPrintZ(&sql_buf, "select txn from {s}.cwal_marker where k = 0", .{schema}) catch return error.Io;
                    if (c.sqlite3_prepare_v2(db, q.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.Sqlite;
                    defer _ = c.sqlite3_finalize(stmt);
                    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.Sqlite;
                    conn.txn = @max(conn.txn, @as(u64, @intCast(c.sqlite3_column_int64(stmt, 0))));
                }
            }
        }
        return conn;
    }

    pub fn schemaName(i: usize) [:0]const u8 {
        return switch (i) {
            0 => "main",
            1 => "m1",
            2 => "m2",
            else => "m3",
        };
    }

    pub fn close(conn: *Conn) void {
        if (conn.db) |db| _ = c.sqlite3_close_v2(db);
        conn.db = null;
        if (conn.snap) |page| _ = c.munmap(@ptrCast(page), snap_page_size);
        conn.snap = null;
        for ([_]*c_int{ &conn.writer_fd, &conn.live_fd, &conn.snap_fd, &conn.alive_fd }) |fd| {
            if (fd.* >= 0) _ = c.close(fd.*);
            fd.* = -1;
        }
        if (conn.id != 0) @atomicStore(?*Conn, &registry[conn.id], null, .seq_cst);
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
        var buf: [1100]u8 = undefined;
        const path = bufPrintZ(&buf, "{s}-cwal-{s}", .{ conn.paths[0], suffix }) catch return error.Io;
        const fd = c.open(path.ptr, c.O_RDWR | c.O_CREAT | c.O_CLOEXEC, @as(c_uint, 0o644));
        if (fd < 0) return error.Io;
        return fd;
    }

    fn lock(fd: c_int, op: c_int) bool {
        while (true) {
            if (c.flock(fd, op) == 0) return true;
            if (c.__errno_location().* != c.EINTR) return false;
        }
    }

    fn openCoordination(conn: *Conn) Error!void {
        conn.alive_fd = try conn.openLockFile("alive");
        conn.writer_fd = try conn.openLockFile("writer");
        conn.live_fd = try conn.openLockFile("live");
        conn.snap_fd = try conn.openLockFile("snap");
        var st: c.struct_stat = undefined;
        if (c.fstat(conn.snap_fd, &st) != 0) return error.Io;
        if (st.st_size < snap_page_size and c.ftruncate(conn.snap_fd, snap_page_size) != 0) return error.Io;
        const mapped = c.mmap(null, snap_page_size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, conn.snap_fd, 0);
        if (mapped == null or @intFromPtr(mapped) == std.math.maxInt(usize)) return error.Io;
        conn.snap = @ptrCast(@alignCast(mapped));

        if (conn.role == .writer and !lock(conn.writer_fd, c.LOCK_EX | c.LOCK_NB)) return error.WriterBusy;
        fault.event("open-alive");
        if (lock(conn.alive_fd, c.LOCK_EX | c.LOCK_NB)) {
            // No other handle has the set open: repair an interrupted commit
            // before SQLite reads any WAL file.
            try conn.recover();
            // A writer that died inside a window left the seqlock odd.
            @atomicStore(u64, &conn.snap.?.seq, 0, .seq_cst);
            @atomicStore(u32, &conn.snap.?.cross, 0, .seq_cst);
            @atomicStore(u32, &conn.snap.?.broken, 0, .seq_cst);
            if (!lock(conn.alive_fd, c.LOCK_SH)) return error.Io;
        } else {
            if (!lock(conn.alive_fd, c.LOCK_SH)) return error.Io;
            if (!conn.markersReadable(@atomicLoad(u64, &conn.snap.?.seq, .seq_cst))) return error.Broken;
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
        }
        var torn = false;
        for (0..conn.nmembers) |i| {
            if (newest.mask & (@as(u32, 1) << @intCast(i)) != 0 and markers[i].txn != newest.txn) torn = true;
        }
        if (torn and !fault.mutated("no-marker-rollback")) {
            last_recovery = "rollback";
            for (0..conn.nmembers) |i| {
                if (markers[i].txn != newest.txn) continue;
                var buf: [1100]u8 = undefined;
                const wal = bufPrintZ(&buf, "{s}-wal", .{conn.paths[i]}) catch return error.Io;
                const fd = c.open(wal.ptr, c.O_RDWR | c.O_CLOEXEC);
                if (fd < 0) return error.ProtocolViolation;
                defer _ = c.close(fd);
                // The torn commit cannot have been checkpointed: the writer
                // checkpoints only between commits.
                const keep = walLastCommitStart(fd) orelse return error.ProtocolViolation;
                fault.event("recover-truncate");
                if (c.ftruncate(fd, keep) != 0) return error.Io;
                fault.event("recover-fsync");
                if (c.fsync(fd) != 0) return error.Io;
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
                if (monotonicNs() > deadline) return;
                _ = c.usleep(100);
            }
            held[m] = true;
        }
        fault.event("ckpt-reset");
        _ = @atomicRmw(u64, &conn.snap.?.ckpt, .And, ~(ckpt_started - 1), .seq_cst);
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

    fn observeWalWrite(conn: *Conn, bytes: []const u8) void {
        if (conn.mode != .cwal or !conn.in_commit) return;
        if (bytes.len == wal_frame_header_size and std.mem.readInt(u32, bytes[4..8], .big) != 0) conn.any_commit_frame = true;
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
        const marked = conn.marker_pending;
        conn.marker_pending = false;
        if (@atomicLoad(u32, &conn.snap.?.broken, .seq_cst) != 0) return 1;
        // A cross-file commit without markers could not be recovered.
        if (conn.cross and !marked and !fault.mutated("no-markers")) {
            conn.violation = true;
            return 1;
        }
        return 0;
    }

    fn startPublication(conn: *Conn) void {
        if (conn.mode != .cwal or !conn.in_commit or conn.window_open or fault.mutated("no-gate")) return;
        // Single-member commits open the window too: otherwise a reader
        // pinning members in order could see a later solo commit on one
        // member but miss an earlier one on another.
        if (!conn.cross and fault.mutated("no-solo-window")) return;
        // No member has published yet: their current headers are the last
        // committed state of the set.
        const page = conn.snap.?;
        for (0..conn.nmembers) |m| {
            if (!conn.readHeader(m, &page.hdr[m])) {
                conn.violation = true;
                return;
            }
        }
        @atomicStore(u32, &page.cross, @intFromBool(conn.cross), .seq_cst);
        fault.event("gate-acquire");
        _ = @atomicRmw(u64, &page.seq, .Add, 1, .seq_cst);
        conn.window_open = true;
        if (test_delay.window_delay_us != 0) _ = c.usleep(test_delay.window_delay_us);
    }

    fn commitPhaseTwo(conn: *Conn) void {
        if (conn.mode != .cwal or !conn.in_commit) return;
        // SQLite runs phase one (WAL frames, sync, wal-index update) for every
        // member before phase two of any, so every member has published and
        // every commit frame is durable.
        fault.event("phase-two");
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
                for (0..conn.nmembers) |m| {
                    if (mask & (@as(u32, 1) << @intCast(m)) == 0) continue;
                    var buf: [128]u8 = undefined;
                    try conn.exec(bufPrintZ(&buf, "update {s}.cwal_marker set txn = {d}, mask = {d} where k = 0", .{ schemaName(m), t, mask }) catch return error.Io);
                }
                conn.marker_pending = true;
                defer conn.marker_pending = false;
                try conn.exec("commit");
                conn.txn = t;
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
            conn.exec("rollback") catch {};
            return err;
        };
        conn.commit() catch |err| {
            conn.exec("rollback") catch {};
            return err;
        };
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
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}
