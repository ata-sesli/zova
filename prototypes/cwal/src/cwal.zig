//! CWAL prototype: coordinated WAL publication and recovery across a small,
//! fixed set of SQLite files (a main database plus attached stores).
//!
//! The VFS wraps SQLite's "unix" VFS. It adds:
//! - fault injection: a global event counter over every write, sync,
//!   truncate, lock and protocol step, with a crash (SIGKILL) at a chosen
//!   event and an optional power-loss model that loses or tears unsynced
//!   writes;
//! - the coordination protocol, enabled per connection (`Mode.cwal`):
//!   a commit gate, a two-slot coordination journal, checkpoint gating and
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
const wal_ckpt_lock = 1;
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
    /// "no-gate" (no gate, or no seqlock window with snapshot reads),
    /// "no-lock-gate", "no-ckpt-gate", "no-salt-check", "no-seq-check",
    /// "no-snapshot-open", "no-solo-window", "always-rollforward",
    /// "always-rollback".
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
};

var unix_vfs: [*c]c.sqlite3_vfs = null;
var cwal_vfs: c.sqlite3_vfs = undefined;

/// Protocol variants. They are set-wide: every process of a set must use the
/// same values.
pub const variant = struct {
    /// Write COMMITTED without an fsync. Recovery then keeps a PREPARED
    /// transaction whose commit frames are durable on every member, instead
    /// of rolling it back. (CWAL_LAZY_COMMIT, default 1.)
    pub var lazy_commit = true;
    /// Readers never wait on the gate: a seqlock marks the publication
    /// window, and a reader that starts inside it opens the members at their
    /// pre-window wal-index headers with sqlite3_snapshot_open.
    /// (CWAL_SNAPSHOT_READS, default 1.)
    pub var snapshot_reads = true;
    /// Test-only: sleep inside the publication window to widen it.
    pub var window_delay_us: u32 = 0;
};

pub fn register() void {
    fault.init();
    variant.lazy_commit = (envU64("CWAL_LAZY_COMMIT") orelse 1) != 0;
    variant.snapshot_reads = (envU64("CWAL_SNAPSHOT_READS") orelse 1) != 0;
    variant.window_delay_us = @intCast(envU64("CWAL_WINDOW_DELAY_US") orelse 0);
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
        if (connFor(f)) |conn| conn.observeWalWrite(f.member, bytes, offset);
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
    return realMethods(f).xShmMap.?(f.real, page, size, extend, out);
}

fn ioShmLock(file: [*c]c.sqlite3_file, offset: c_int, n: c_int, flags: c_int) callconv(.c) c_int {
    const f = asFile(file);
    fault.event("shm-lock");
    const conn = connFor(f);
    if (conn) |cn| {
        if (cn.mode == .cwal and offset == wal_ckpt_lock and n == 1 and flags == c.SQLITE_SHM_LOCK | c.SQLITE_SHM_EXCLUSIVE) {
            if (!fault.mutated("no-ckpt-gate") and !cn.checkpointAllowed()) return c.SQLITE_BUSY;
        }
    }
    const rc = realMethods(f).xShmLock.?(f.real, offset, n, flags);
    if (conn) |cn| {
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
// Coordination journal
// ---------------------------------------------------------------------------

pub const State = enum(u32) { idle = 0, prepared = 1, committed = 2, broken = 3 };

/// Rollback point of one member: the last committed WAL frame and the WAL
/// salts when the transaction started.
pub const Part = struct {
    member: u32 = 0,
    frames: u32 = 0,
    page_size: u32 = 0,
    salt: [8]u8 = @splat(0),
};

pub const Record = struct {
    seq: u64 = 0,
    state: State = .idle,
    txn: u64 = 0,
    nparts: u32 = 0,
    parts: [max_members]Part = @splat(.{}),
};

const journal_magic: u32 = 0x4357_414c; // "CWAL"
const record_size = 128;
/// One slot per 4 KiB page, so a torn write of one slot cannot damage the
/// other on devices that tear whole sectors.
const slot_stride = 4096;

fn fnv(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| h = (h ^ b) *% 0x100000001b3;
    return h;
}

fn encode(r: Record) [record_size]u8 {
    var b: [record_size]u8 = @splat(0);
    std.mem.writeInt(u32, b[0..4], journal_magic, .little);
    std.mem.writeInt(u64, b[4..12], r.seq, .little);
    std.mem.writeInt(u32, b[12..16], @backingInt(r.state), .little);
    std.mem.writeInt(u64, b[16..24], r.txn, .little);
    std.mem.writeInt(u32, b[24..28], r.nparts, .little);
    for (r.parts, 0..) |p, i| {
        const o = 28 + i * 20;
        std.mem.writeInt(u32, b[o..][0..4], p.member, .little);
        std.mem.writeInt(u32, b[o + 4 ..][0..4], p.frames, .little);
        std.mem.writeInt(u32, b[o + 8 ..][0..4], p.page_size, .little);
        @memcpy(b[o + 12 ..][0..8], &p.salt);
    }
    std.mem.writeInt(u64, b[120..128], fnv(b[0..120]), .little);
    return b;
}

fn decode(b: *const [record_size]u8) ?Record {
    if (std.mem.readInt(u32, b[0..4], .little) != journal_magic) return null;
    if (std.mem.readInt(u64, b[120..128], .little) != fnv(b[0..120])) return null;
    var r: Record = .{};
    r.seq = std.mem.readInt(u64, b[4..12], .little);
    r.state = std.enums.fromInt(State, std.mem.readInt(u32, b[12..16], .little)) orelse return null;
    r.txn = std.mem.readInt(u64, b[16..24], .little);
    r.nparts = std.mem.readInt(u32, b[24..28], .little);
    if (r.nparts > max_members) return null;
    for (&r.parts, 0..) |*p, i| {
        const o = 28 + i * 20;
        p.member = std.mem.readInt(u32, b[o..][0..4], .little);
        p.frames = std.mem.readInt(u32, b[o + 4 ..][0..4], .little);
        p.page_size = std.mem.readInt(u32, b[o + 8 ..][0..4], .little);
        @memcpy(&p.salt, b[o + 12 ..][0..8]);
    }
    return r;
}

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

/// Whether the WAL behind `fd` holds a commit frame after the part's
/// rollback point that SQLite's own WAL recovery would accept: the header is
/// valid, and every frame up to it carries the header salts and continues
/// the checksum chain. With different salts the transaction reset the WAL,
/// so its frames start at frame 1.
fn walHasCommitBeyond(fd: c_int, p: Part) bool {
    var header: [wal_header_size]u8 = undefined;
    if (c.pread(fd, &header, header.len, 0) != header.len) return false;
    const magic = std.mem.readInt(u32, header[0..4], .big);
    if (magic & 0xffff_fffe != 0x377f_0682) return false;
    const big = magic & 1 != 0;
    const page_size = std.mem.readInt(u32, header[8..12], .big);
    if (page_size < 512 or page_size > 65536 or page_size & (page_size - 1) != 0) return false;
    var s: [2]u32 = .{ 0, 0 };
    walChecksum(big, header[0..24], &s);
    if (s[0] != std.mem.readInt(u32, header[24..28], .big) or s[1] != std.mem.readInt(u32, header[28..32], .big)) return false;
    const boundary: u64 = if (std.mem.eql(u8, header[16..24], &p.salt)) p.frames else 0;
    const frame_size: usize = wal_frame_header_size + page_size;
    const frame = std.heap.c_allocator.alloc(u8, frame_size) catch return false;
    defer std.heap.c_allocator.free(frame);
    var i: u64 = 1;
    while (true) : (i += 1) {
        const offset: i64 = @intCast(wal_header_size + (i - 1) * frame_size);
        if (c.pread(fd, frame.ptr, frame_size, offset) != frame_size) return false;
        if (!std.mem.eql(u8, frame[8..16], header[16..24])) return false;
        if (std.mem.readInt(u32, frame[0..4], .big) == 0) return false;
        walChecksum(big, frame[0..8], &s);
        walChecksum(big, frame[wal_frame_header_size..], &s);
        if (s[0] != std.mem.readInt(u32, frame[16..20], .big) or s[1] != std.mem.readInt(u32, frame[20..24], .big)) return false;
        if (i > boundary and std.mem.readInt(u32, frame[4..8], .big) != 0) return true;
    }
}

/// Seqlock page shared by every handle of a set (`main.db-cwal-snap`). The
/// writer stores each member's wal-index header, then makes `seq` odd for
/// the publication window, and even again after it.
const SnapPage = extern struct {
    seq: u64,
    reserved: [56]u8,
    hdr: [max_members][48]u8,
};
const snap_page_size = 4096;

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
    prepared_records: u64 = 0,
    gate_wait_ns: u64 = 0,
    checkpoint_denied: u64 = 0,
    /// Reads that started inside a publication window and used snapshots.
    snapshot_reads: u64 = 0,
    /// Reads retried because a window started while pinning members.
    seq_retries: u64 = 0,
    /// Snapshot opens that failed, so the reader waited for the window.
    snapshot_waits: u64 = 0,
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
    gate_fd: c_int = -1,
    alive_fd: c_int = -1,
    writer_fd: c_int = -1,
    live_fd: c_int = -1,
    snap_fd: c_int = -1,
    snap: ?*SnapPage = null,
    journal_path: [:0]u8 = undefined,
    journal: ?*File = null,
    seq: u64 = 0,
    txn: u64 = 0,
    /// The publication window is open: the gate is held, or the seqlock is
    /// odd.
    window_open: bool = false,
    /// COMMITTED was written without an fsync (lazy commit).
    commit_unsynced: bool = false,
    in_commit: bool = false,
    prepared: bool = false,
    any_commit_frame: bool = false,
    pending_parts: [max_members]Part = @splat(.{}),
    pending_nparts: u32 = 0,
    violation: bool = false,
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
        if (conn.journal) |j| {
            _ = j.base.pMethods.*.xClose.?(&j.base);
            allocator.free(@as([*]align(8) u8, @ptrCast(@alignCast(j)))[0..@intCast(cwal_vfs.szOsFile)]);
            conn.journal = null;
        }
        if (conn.snap) |page| _ = c.munmap(@ptrCast(page), snap_page_size);
        conn.snap = null;
        for ([_]*c_int{ &conn.gate_fd, &conn.writer_fd, &conn.live_fd, &conn.snap_fd, &conn.alive_fd }) |fd| {
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
        conn.gate_fd = try conn.openLockFile("gate");
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
        conn.journal_path = std.fmt.allocPrintSentinel(allocator, "{s}-cwal", .{conn.paths[0]}, 0) catch return error.Io;
        const mem = allocator.alignedAlloc(u8, .@"8", @intCast(cwal_vfs.szOsFile)) catch return error.Io;
        const jf: *File = @ptrCast(@alignCast(mem.ptr));
        var out_flags: c_int = 0;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_SUPER_JOURNAL;
        if (vfsOpen(&cwal_vfs, conn.journal_path.ptr, &jf.base, flags, &out_flags) != c.SQLITE_OK) {
            allocator.free(mem);
            return error.Io;
        }
        conn.journal = jf;

        if (conn.role == .writer and !lock(conn.writer_fd, c.LOCK_EX | c.LOCK_NB)) return error.WriterBusy;
        fault.event("open-alive");
        if (lock(conn.alive_fd, c.LOCK_EX | c.LOCK_NB)) {
            // No other handle has the set open: repair an interrupted commit
            // before SQLite reads any WAL file.
            try conn.recover();
            // A writer that died inside a window left the seqlock odd.
            @atomicStore(u64, &conn.snap.?.seq, 0, .seq_cst);
            if (!lock(conn.alive_fd, c.LOCK_SH)) return error.Io;
        } else {
            if (!lock(conn.alive_fd, c.LOCK_SH)) return error.Io;
            if (!lock(conn.gate_fd, c.LOCK_SH)) return error.Io;
            const r = conn.readJournal();
            const readable = conn.journalReadable(r.state);
            _ = c.flock(conn.gate_fd, c.LOCK_UN);
            if (!readable) return error.Broken;
            conn.seq = r.seq;
        }
        if (conn.role == .writer) {
            // A previous writer may have left COMMITTED unsynced. Make it
            // durable before this writer checkpoints or resets any WAL.
            if (variant.lazy_commit) {
                const j = conn.journal.?;
                if (j.base.pMethods.*.xSync.?(&j.base, c.SQLITE_SYNC_NORMAL) != c.SQLITE_OK) return error.Io;
            }
            // A writer that died inside a single-member commit's window left
            // the seqlock odd with a clean journal, so no recovery ran. Close
            // that window, or every later window would flip its parity.
            const page = conn.snap.?;
            if (@atomicLoad(u64, &page.seq, .seq_cst) & 1 != 0) _ = @atomicRmw(u64, &page.seq, .Add, 1, .seq_cst);
            // The journal is clean: announce a live writer (see writerLive).
            if (!lock(conn.live_fd, c.LOCK_EX)) return error.Io;
        }
    }

    pub fn readJournal(conn: *Conn) Record {
        const j = conn.journal.?;
        var best: Record = .{};
        for (0..2) |slot| {
            var b: [record_size]u8 = undefined;
            const rc = j.base.pMethods.*.xRead.?(&j.base, &b, record_size, @intCast(slot * slot_stride));
            if (rc != c.SQLITE_OK) continue;
            if (decode(&b)) |r| {
                if (r.seq > best.seq) best = r;
            }
        }
        return best;
    }

    fn writeJournal(conn: *Conn, r_in: Record, sync: bool) Error!void {
        var r = r_in;
        r.seq = conn.seq + 1;
        const b = encode(r);
        const j = conn.journal.?;
        fault.event("journal-write");
        if (j.base.pMethods.*.xWrite.?(&j.base, &b, record_size, @intCast((r.seq % 2) * slot_stride)) != c.SQLITE_OK) return error.Io;
        conn.seq = r.seq;
        if (sync) {
            if (j.base.pMethods.*.xSync.?(&j.base, c.SQLITE_SYNC_NORMAL) != c.SQLITE_OK) return error.Io;
            conn.commit_unsynced = false;
        }
    }

    fn syncJournal(conn: *Conn) Error!void {
        if (!conn.commit_unsynced) return;
        const j = conn.journal.?;
        if (j.base.pMethods.*.xSync.?(&j.base, c.SQLITE_SYNC_NORMAL) != c.SQLITE_OK) return error.Io;
        conn.commit_unsynced = false;
    }

    /// Whether every part of a PREPARED record has a durable commit frame
    /// after its rollback point, so the transaction completed on every
    /// member and only its COMMITTED record was lost.
    fn preparedComplete(conn: *Conn, r: Record) Error!bool {
        if (fault.mutated("always-rollforward")) return true;
        if (fault.mutated("always-rollback") or !variant.lazy_commit) return false;
        for (r.parts[0..r.nparts]) |p| {
            var buf: [1100]u8 = undefined;
            const wal = bufPrintZ(&buf, "{s}-wal", .{conn.paths[p.member]}) catch return error.Io;
            const fd = c.open(wal.ptr, c.O_RDONLY | c.O_CLOEXEC);
            if (fd < 0) return false;
            defer _ = c.close(fd);
            if (!walHasCommitBeyond(fd, p)) return false;
        }
        return true;
    }

    /// Repair an interrupted cross-file commit. Runs only while this handle
    /// is the only one with the set open, before SQLite opens any member.
    /// Every step is idempotent, and the journal is marked idle last, so a
    /// crash during recovery leaves it to be run again.
    fn recover(conn: *Conn) Error!void {
        const r = conn.readJournal();
        conn.seq = r.seq;
        conn.txn = r.txn;
        if (r.state != .prepared and r.state != .broken) return;
        fault.event("recover-begin");
        for (r.parts[0..r.nparts]) |p| {
            if (p.member >= conn.nmembers) return error.ProtocolViolation;
        }
        // A BROKEN transaction was rolled back by SQLite and is never kept.
        const keep_all = r.state == .prepared and try conn.preparedComplete(r);
        if (keep_all) fault.event("recover-forward");
        last_recovery = if (keep_all) "forward" else "rollback";
        if (!keep_all) for (r.parts[0..r.nparts]) |p| {
            var buf: [1100]u8 = undefined;
            const wal = bufPrintZ(&buf, "{s}-wal", .{conn.paths[p.member]}) catch return error.Io;
            const fd = c.open(wal.ptr, c.O_RDWR | c.O_CLOEXEC);
            if (fd < 0) continue;
            defer _ = c.close(fd);
            var header: [wal_header_size]u8 = undefined;
            const n = c.pread(fd, &header, header.len, 0);
            // Same salts: keep frames up to the rollback point. Different
            // salts (or no header): the interrupted transaction reset the
            // WAL, which SQLite does only after every frame has been copied
            // into the database, so an empty WAL is the prior state.
            const keep: i64 = if (p.frames != 0 and n == header.len and (fault.mutated("no-salt-check") or std.mem.eql(u8, header[16..24], &p.salt)))
                wal_header_size + @as(i64, p.frames) * (wal_frame_header_size + @as(i64, p.page_size))
            else
                0;
            var st: c.struct_stat = undefined;
            if (c.fstat(fd, &st) != 0) return error.Io;
            if (st.st_size > keep) {
                fault.event("recover-truncate");
                if (c.ftruncate(fd, keep) != 0) return error.Io;
                fault.event("recover-fsync");
                if (c.fsync(fd) != 0) return error.Io;
            }
        };
        for (0..conn.nmembers) |i| {
            var buf: [1100]u8 = undefined;
            const shm = bufPrintZ(&buf, "{s}-shm", .{conn.paths[i]}) catch return error.Io;
            fault.event("recover-unlink-shm");
            _ = c.unlink(shm.ptr);
        }
        try conn.writeJournal(.{ .state = .idle, .txn = r.txn }, true);
    }

    /// Whether the members' published states form one committed state.
    /// PREPARED is fine while the writer that wrote it is alive: outside the
    /// publication window (which readers wait out on the gate) either no
    /// member or every member has published. A crashed writer leaves
    /// PREPARED without a live lock, and the set needs recovery.
    fn journalReadable(conn: *Conn, state: State) bool {
        return switch (state) {
            .idle, .committed => true,
            .broken => false,
            .prepared => conn.role == .reader and conn.writerLive(),
        };
    }

    /// The writer holds `-live` from the end of a successful open (journal
    /// clean) until it closes or dies. A writer that finds PREPARED never
    /// takes it, so it always belongs to the writer of the current record.
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
        var allowed = conn.role == .writer and !conn.in_commit and !conn.window_open and switch (conn.readJournal().state) {
            .idle, .committed => true,
            .prepared, .broken => false,
        };
        // A checkpoint can reset a WAL, after which recovery could no longer
        // see that a lazily committed transaction completed.
        if (allowed) conn.syncJournal() catch {
            allowed = false;
        };
        if (!allowed) conn.stats.checkpoint_denied += 1;
        return allowed;
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

    fn readBoundary(conn: *Conn, member: usize) ?Part {
        var raw: [48]u8 = undefined;
        if (!conn.readHeader(member, &raw)) return null;
        const sz = std.mem.readInt(u16, raw[14..16], .native);
        var p: Part = .{
            .member = @intCast(member),
            .frames = std.mem.readInt(u32, raw[16..20], .native),
            .page_size = (@as(u32, sz) & 0xfe00) | ((@as(u32, sz) & 1) << 16),
        };
        @memcpy(&p.salt, raw[32..40]);
        return p;
    }

    fn observeWalWrite(conn: *Conn, member: u8, bytes: []const u8, offset: i64) void {
        if (conn.mode != .cwal or !conn.in_commit) return;
        if (bytes.len == wal_frame_header_size and std.mem.readInt(u32, bytes[4..8], .big) != 0) conn.any_commit_frame = true;
        if (!conn.prepared) return;
        for (conn.pending_parts[0..conn.pending_nparts]) |p| {
            if (p.member != member or p.frames == 0 or offset == 0) continue;
            const boundary = wal_header_size + @as(i64, p.frames) * (wal_frame_header_size + @as(i64, p.page_size));
            if (offset < boundary) conn.violation = true;
        }
    }

    fn acquireGate(conn: *Conn, op: c_int) bool {
        const start = monotonicNs();
        const ok = lock(conn.gate_fd, op);
        conn.stats.gate_wait_ns += monotonicNs() - start;
        return ok;
    }

    /// End the publication window: release the gate, or make the seqlock
    /// even again.
    fn closeWindow(conn: *Conn) void {
        fault.event("gate-release");
        if (variant.snapshot_reads) {
            _ = @atomicRmw(u64, &conn.snap.?.seq, .Add, 1, .seq_cst);
        } else {
            _ = c.flock(conn.gate_fd, c.LOCK_UN);
        }
        conn.window_open = false;
    }

    fn commitHook(arg: ?*anyopaque) callconv(.c) c_int {
        const conn: *Conn = @ptrCast(@alignCast(arg.?));
        if (conn.role != .writer) return 1;
        fault.event("commit-hook");
        conn.in_commit = true;
        conn.any_commit_frame = false;
        conn.pending_nparts = 0;
        for (0..conn.nmembers) |m| {
            if (!conn.write_locked[m]) continue;
            conn.pending_parts[conn.pending_nparts] = conn.readBoundary(m) orelse {
                conn.violation = true;
                return 1;
            };
            conn.pending_nparts += 1;
        }
        if (conn.pending_nparts >= 2) {
            conn.txn += 1;
            var r: Record = .{ .state = .prepared, .txn = conn.txn, .nparts = conn.pending_nparts };
            r.parts = conn.pending_parts;
            conn.writeJournal(r, true) catch return 1;
            conn.prepared = true;
            conn.stats.prepared_records += 1;
        }
        return 0;
    }

    fn startPublication(conn: *Conn) void {
        if (conn.mode != .cwal or !conn.in_commit or conn.window_open or fault.mutated("no-gate")) return;
        if (variant.snapshot_reads) {
            // Single-member commits open the window too: otherwise a reader
            // pinning members in order could see a later solo commit on one
            // member but miss an earlier one on another.
            if (!conn.prepared and fault.mutated("no-solo-window")) return;
            // No member has published yet: their current headers are the
            // last committed state of the set.
            const page = conn.snap.?;
            for (0..conn.nmembers) |m| {
                if (!conn.readHeader(m, &page.hdr[m])) {
                    conn.violation = true;
                    return;
                }
            }
            fault.event("gate-acquire");
            _ = @atomicRmw(u64, &page.seq, .Add, 1, .seq_cst);
        } else {
            fault.event("gate-acquire");
            if (!conn.acquireGate(c.LOCK_EX)) {
                conn.violation = true;
                return;
            }
        }
        conn.window_open = true;
        if (variant.window_delay_us != 0) _ = c.usleep(variant.window_delay_us);
    }

    fn commitPhaseTwo(conn: *Conn) void {
        if (conn.mode != .cwal or !conn.in_commit) return;
        // SQLite runs phase one (WAL frames, sync, wal-index update) for every
        // member before phase two of any, so every member has published and
        // every commit frame is durable.
        fault.event("phase-two");
        if (conn.window_open) conn.closeWindow();
        if (conn.prepared) {
            // With lazy commit, recovery can tell from the WAL files that
            // this transaction completed, so COMMITTED needs no fsync.
            conn.writeJournal(.{ .state = .committed, .txn = conn.txn }, !variant.lazy_commit) catch {};
            if (variant.lazy_commit) conn.commit_unsynced = true;
            conn.prepared = false;
        }
        conn.in_commit = false;
        conn.stats.commits += 1;
    }

    fn rollbackHook(arg: ?*anyopaque) callconv(.c) void {
        const conn: *Conn = @ptrCast(@alignCast(arg.?));
        if (!conn.in_commit) return;
        if (conn.prepared) {
            // A commit frame already published on one member cannot be taken
            // back while other handles may read it: mark the set broken
            // before the window ends.
            const state: State = if (conn.any_commit_frame) .broken else .idle;
            conn.writeJournal(.{ .state = state, .txn = conn.txn }, true) catch {};
            conn.prepared = false;
        }
        if (conn.window_open) conn.closeWindow();
        conn.in_commit = false;
    }

    /// Begin a read transaction that sees every member at one point between
    /// commits. `gap_us` waits between pinning members, to widen the window a
    /// mixed view needs.
    pub fn beginRead(conn: *Conn, gap_us: u32) Error!void {
        if (conn.mode == .cwal and variant.snapshot_reads) return conn.beginSnapshotRead(gap_us);
        if (conn.mode == .cwal) {
            if (!conn.acquireGate(c.LOCK_SH)) return error.Io;
            const r = conn.readJournal();
            if (!conn.journalReadable(r.state)) {
                _ = c.flock(conn.gate_fd, c.LOCK_UN);
                return error.Broken;
            }
        }
        defer if (conn.mode == .cwal) {
            _ = c.flock(conn.gate_fd, c.LOCK_UN);
        };
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

    /// Seqlock read. Outside a publication window, pin the members normally
    /// and retry if a window started meanwhile. Inside one, open each member
    /// at the header the writer saved before any member published.
    fn beginSnapshotRead(conn: *Conn, gap_us: u32) Error!void {
        const page = conn.snap.?;
        while (true) {
            const s1 = @atomicLoad(u64, &page.seq, .seq_cst);
            // Read the journal after the sequence: a writer that rolls back
            // after publishing marks the set broken before the window ends.
            if (!conn.journalReadable(conn.readJournal().state)) return error.Broken;
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
            for (0..conn.nmembers) |m| {
                if (m != 0 and gap_us != 0) _ = c.usleep(gap_us);
                var snapshot: c.sqlite3_snapshot = .{ .hidden = hdrs[m] };
                if (c.sqlite3_snapshot_open(conn.db, schemaName(m).ptr, &snapshot) != c.SQLITE_OK) {
                    opened = false;
                    break;
                }
            }
            if (opened) {
                conn.stats.snapshot_reads += 1;
                return;
            }
            // The saved state is no longer available (rare: SQLite could not
            // keep a read mark at it). Wait for the window to end.
            conn.exec("rollback") catch {};
            conn.stats.snapshot_waits += 1;
            const start = monotonicNs();
            defer conn.stats.gate_wait_ns += monotonicNs() - start;
            while (@atomicLoad(u64, &page.seq, .seq_cst) == s1) {
                if (!conn.writerLive()) return error.Broken;
                _ = c.usleep(50);
            }
        }
    }
};

/// Outcome of the last recovery this process ran: "none", "forward" or
/// "rollback".
pub var last_recovery: []const u8 = "none";

pub fn monotonicNs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}
