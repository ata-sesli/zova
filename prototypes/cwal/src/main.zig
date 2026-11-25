//! CWAL prototype driver: seeds a two-file set or an N-file set, runs a
//! crashable writer, concurrent readers, recovery and the consistency
//! checker, and benchmarks.
const std = @import("std");
const c = @import("c");

fn bufPrintZ(buf: []u8, comptime fmt: []const u8, args: anytype) std.fmt.BufPrintError![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, fmt, args, 0);
}
const cwal = @import("cwal.zig");
const Conn = cwal.Conn;

const max_path = 1024;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = c.write(1, text.ptr, text.len);
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    out("FAIL " ++ fmt ++ "\n", args);
    cwal.flushPending();
    c.exit(1);
}

const Args = struct {
    list: []const [:0]const u8,

    fn get(self: Args, name: []const u8) ?[]const u8 {
        var i: usize = 2;
        while (i + 1 < self.list.len) : (i += 1) {
            if (std.mem.eql(u8, self.list[i], name)) return self.list[i + 1];
        }
        return null;
    }

    fn int(self: Args, name: []const u8, default: u64) u64 {
        const v = self.get(name) orelse return default;
        return std.fmt.parseInt(u64, v, 10) catch die("bad {s}", .{name});
    }

    fn mode(self: Args) cwal.Mode {
        return std.meta.stringToEnum(cwal.Mode, self.get("--mode") orelse "cwal") orelse die("bad --mode", .{});
    }
};

const Paths = struct {
    main: [max_path]u8 = undefined,
    store: [max_path]u8 = undefined,
    main_len: usize = 0,
    store_len: usize = 0,

    fn init(dir: []const u8) Paths {
        var p: Paths = .{};
        p.main_len = (std.fmt.bufPrint(&p.main, "{s}/main.db", .{dir}) catch unreachable).len;
        p.store_len = (std.fmt.bufPrint(&p.store, "{s}/store.db", .{dir}) catch unreachable).len;
        return p;
    }

    fn list(p: *const Paths) [2][]const u8 {
        return .{ p.main[0..p.main_len], p.store[0..p.store_len] };
    }
};

fn queryInt(conn: *Conn, sql: [:0]const u8) i64 {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(conn.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) die("prepare {s}: {s}", .{ sql, c.sqlite3_errmsg(conn.db) });
    defer _ = c.sqlite3_finalize(stmt);
    const rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_ROW) die("step {s}: {s}", .{ sql, c.sqlite3_errmsg(conn.db) });
    return c.sqlite3_column_int64(stmt, 0);
}

fn queryText(conn: *Conn, sql: [:0]const u8, buf: []u8) []const u8 {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(conn.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) die("prepare {s}", .{sql});
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) die("step {s}", .{sql});
    const text = std.mem.span(c.sqlite3_column_text(stmt, 0));
    const n = @min(text.len, buf.len);
    @memcpy(buf[0..n], text[0..n]);
    return buf[0..n];
}

fn execFmt(conn: *Conn, comptime fmt: []const u8, args: anytype) cwal.Error!void {
    var buf: [1024]u8 = undefined;
    try conn.exec(bufPrintZ(&buf, fmt, args) catch unreachable);
}

fn autocommitFmt(conn: *Conn, comptime fmt: []const u8, args: anytype) cwal.Error!void {
    var buf: [1024]u8 = undefined;
    try conn.autocommit(bufPrintZ(&buf, fmt, args) catch unreachable);
}

// ---------------------------------------------------------------------------
// seed
// ---------------------------------------------------------------------------

fn seedOne(path: []const u8, schema: [:0]const u8) void {
    var buf: [max_path]u8 = undefined;
    const z = bufPrintZ(&buf, "{s}", .{path}) catch unreachable;
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(z.ptr, &db) != c.SQLITE_OK) die("open {s}", .{path});
    var msg: [*c]u8 = null;
    if (c.sqlite3_exec(db, schema.ptr, null, null, &msg) != c.SQLITE_OK) die("seed {s}: {s}", .{ path, msg });
    _ = c.sqlite3_close(db);
}

fn cmdSeed(dir: []const u8) void {
    const p = Paths.init(dir);
    const l = p.list();
    seedOne(l[0], "pragma journal_mode=wal; create table pairs(id integer primary key, v blob);" ++
        "create table solo(id integer primary key, v blob); create table bulk(pid integer, v blob);");
    seedOne(l[1], "pragma journal_mode=wal; create table pairs_s(id integer primary key, v blob);" ++
        "create table solo_s(id integer primary key, v blob); create table bulk_s(pid integer, v blob);");
    out("seeded\n", .{});
}

// ---------------------------------------------------------------------------
// writer
// ---------------------------------------------------------------------------

const bulk_rows = 80;

fn installTriggers(conn: *Conn) !void {
    // TEMP triggers make one statement write both files, so an implicit
    // (autocommit) statement is a cross-file transaction.
    try conn.exec("create temp trigger mirror after insert on main.pairs begin " ++
        "insert into pairs_s(id, v) values (new.id, new.v); end");
    try conn.exec("create temp trigger mirror_bulk after insert on main.bulk begin " ++
        "insert into bulk_s(pid, v) values (new.pid, new.v); end");
}

fn openSet(dir: []const u8, options: cwal.Options) cwal.Error!*Conn {
    const p = Paths.init(dir);
    const l = p.list();
    return Conn.open(&l, options);
}

fn cmdWriter(dir: []const u8, args: Args) void {
    const mode = args.mode();
    const rounds = args.int("--rounds", 30);
    const conn = openSet(dir, .{ .mode = mode, .role = .writer, .cache_pages = 10 }) catch |err| {
        out("writer-open-error {s}\n", .{@errorName(err)});
        cwal.flushPending();
        c.exit(if (err == error.Broken) 3 else 2);
    };
    installTriggers(conn) catch die("triggers", .{});
    var pair = queryInt(conn, "select coalesce(max(id), 0) from main.pairs") + 1;
    var solo = queryInt(conn, "select coalesce(max(id), 0) from main.solo") + 1;
    var solo_s = queryInt(conn, "select coalesce(max(id), 0) from solo_s") + 1;
    const delay_us = args.int("--delay-us", 0);
    // "passive" keeps the writer from waiting for readers in RESTART and
    // TRUNCATE checkpoints, so reader tests overlap many commits.
    const passive_only = std.mem.eql(u8, args.get("--ckpt") orelse "all", "passive");
    var r: u64 = 0;
    while (r < rounds) : (r += 1) {
        if (delay_us != 0) _ = c.usleep(@intCast(delay_us));
        switch (r % 6) {
            0 => {
                execFmt(conn, "begin; insert into main.pairs values ({d}, randomblob(300))", .{pair}) catch die("explicit pair", .{});
                conn.commit() catch die("explicit pair commit", .{});
                out("ack pair {d}\n", .{pair});
                pair += 1;
            },
            1 => {
                // With commit markers this runs in an explicit transaction.
                autocommitFmt(conn, "insert into main.pairs values ({d}, randomblob(300))", .{pair}) catch die("implicit pair", .{});
                out("ack pair {d}\n", .{pair});
                pair += 1;
            },
            2 => {
                execFmt(conn, "insert into main.solo values ({d}, randomblob(100))", .{solo}) catch die("solo", .{});
                out("ack solo {d}\n", .{solo});
                solo += 1;
            },
            3 => {
                execFmt(conn, "insert into solo_s values ({d}, randomblob(100))", .{solo_s}) catch die("solo_s", .{});
                out("ack solos {d}\n", .{solo_s});
                solo_s += 1;
            },
            4 => {
                // Larger than the page cache, so SQLite spills uncommitted
                // frames into both WAL files before the commit.
                execFmt(conn, "begin; insert into main.pairs values ({d}, randomblob(300)); " ++
                    "with recursive s(x) as (select 1 union all select x + 1 from s where x < {d}) " ++
                    "insert into main.bulk select {d}, randomblob(1500) from s", .{ pair, bulk_rows, pair }) catch die("spill pair", .{});
                conn.commit() catch die("spill pair commit", .{});
                out("ack pair {d}\n", .{pair});
                pair += 1;
            },
            else => {
                // PASSIVE copies frames; RESTART and TRUNCATE make the next
                // writer reuse the WAL from frame 0 (RESTART without
                // shrinking the file).
                const modes = [_]c_int{ c.SQLITE_CHECKPOINT_PASSIVE, c.SQLITE_CHECKPOINT_RESTART, c.SQLITE_CHECKPOINT_TRUNCATE };
                _ = c.sqlite3_wal_checkpoint_v2(conn.db, null, if (passive_only) modes[0] else modes[(r / 6) % 3], null, null);
            },
        }
    }
    conn.close();
    cwal.flushPending();
    out("events={d}\n", .{cwal.fault.count()});
}

// ---------------------------------------------------------------------------
// N-file sets: main.db plus s1.db .. s{N-1}.db, each with table t. A
// transaction k writes one row to each file of its mask; every row carries
// k, the transaction's commit-marker number (0 for single-file
// transactions), its mask and its file count.
// ---------------------------------------------------------------------------

const NSet = struct {
    bufs: [cwal.max_members][max_path]u8 = undefined,
    names: [cwal.max_members][]const u8 = undefined,
    n: usize = 0,

    fn fill(set: *NSet, dir: []const u8, n: usize) void {
        if (n < 2 or n > cwal.max_members) die("--files must be 2..{d}", .{cwal.max_members});
        set.n = n;
        for (0..n) |i| {
            set.names[i] = if (i == 0)
                std.fmt.bufPrint(&set.bufs[i], "{s}/main.db", .{dir}) catch unreachable
            else
                std.fmt.bufPrint(&set.bufs[i], "{s}/s{d}.db", .{ dir, i }) catch unreachable;
        }
    }

    fn list(set: *const NSet) []const []const u8 {
        return set.names[0..set.n];
    }
};

fn nFiles(args: Args) usize {
    return @intCast(args.int("--files", 2));
}

fn openN(dir: []const u8, n: usize, options: cwal.Options) cwal.Error!*Conn {
    var set: NSet = .{};
    set.fill(dir, n);
    return Conn.open(set.list(), options);
}

/// `with u(k, n, mask, txn, f) as (...) <tail>` over every file of the set.
fn unionSql(buf: []u8, n: usize, comptime tail: []const u8) [:0]const u8 {
    var len = (std.fmt.bufPrint(buf, "with u(k, n, mask, txn, f) as (", .{}) catch unreachable).len;
    for (0..n) |i| {
        len += (std.fmt.bufPrint(buf[len..], "{s}select k, n, mask, txn, {d} from {s}.t", .{ if (i == 0) "" else " union all ", i, Conn.schemaName(i) }) catch die("sql too long", .{})).len;
    }
    const rest = bufPrintZ(buf[len..], ") " ++ tail, .{}) catch die("sql too long", .{});
    return buf[0 .. len + rest.len :0];
}

/// One read's consistency, as four counts: transactions whose rows
/// disagree (count, file set, mask, number) or sit in a file outside their
/// mask; distinct k; max k (with the previous, the prefix property); and
/// marker numbers shared by two transactions.
const n_check_tail =
    "select (select count(*) from (select k from u group by k having count(*) != min(n) or min(n) != max(n) " ++
    "or min(mask) != max(mask) or min(txn) != max(txn) or sum(1 << f) != min(mask))), " ++
    "(select count(distinct k) from u), (select coalesce(max(k), 0) from u), " ++
    "(select count(*) from (select txn from u where txn > 0 group by txn having min(k) != max(k)))";

fn queryRow(conn: *Conn, sql: [:0]const u8, row: []i64) void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(conn.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) die("prepare: {s}", .{c.sqlite3_errmsg(conn.db)});
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) die("step: {s}", .{c.sqlite3_errmsg(conn.db)});
    for (row, 0..) |*v, i| v.* = c.sqlite3_column_int64(stmt, @intCast(i));
}

const NState = struct { bad: i64, distinct: i64, max_k: i64, shared_txn: i64 };

fn nState(conn: *Conn, n: usize) NState {
    var buf: [8192]u8 = undefined;
    var row: [4]i64 = undefined;
    queryRow(conn, unionSql(&buf, n, n_check_tail), &row);
    return .{ .bad = row[0], .distinct = row[1], .max_k = row[2], .shared_txn = row[3] };
}

fn cmdNSeed(dir: []const u8, args: Args) void {
    var set: NSet = .{};
    set.fill(dir, nFiles(args));
    for (set.list()) |path| seedOne(path, "pragma journal_mode=wal; create table t(k integer primary key, txn integer not null, mask integer not null, n integer not null, v blob);");
    out("seeded files={d}\n", .{set.n});
}

/// Transactions k = max + 1, ...: odd k writes one random file
/// (autocommit), even k a random subset of 2..N files (explicit
/// transaction with markers). Every tenth round checkpoints instead. Prints
/// "try k txn" before and "ack k txn" after each commit. With --use-files M,
/// the run writes only M randomly chosen files of the set; with --file-mask,
/// only the files in that mask (one file: single-file commits only).
fn cmdNWriter(dir: []const u8, args: Args) void {
    const mode = args.mode();
    const n = nFiles(args);
    const rounds = args.int("--rounds", 30);
    const conn = openN(dir, n, .{ .mode = mode, .role = .writer, .cache_pages = 10 }) catch |err| {
        out("writer-open-error {s}\n", .{@errorName(err)});
        cwal.flushPending();
        c.exit(if (err == error.Broken) 3 else 2);
    };
    var buf: [8192]u8 = undefined;
    var k = queryInt(conn, unionSql(&buf, n, "select coalesce(max(k), 0) from u")) + 1;
    var prng = std.Random.DefaultPrng.init(args.int("--seed", 1) *% 0x9e3779b97f4a7c15 +% @as(u64, @intCast(k)));
    const rand = prng.random();
    const delay_us = args.int("--delay-us", 0);
    const passive_only = std.mem.eql(u8, args.get("--ckpt") orelse "all", "passive");
    // The run's working set: files[0..used].
    var files: [cwal.max_members]usize = undefined;
    for (0..n) |i| files[i] = i;
    var used: usize = @intCast(@min(n, @max(2, args.int("--use-files", n))));
    for (0..used) |i| std.mem.swap(usize, &files[i], &files[i + rand.uintLessThan(usize, n - i)]);
    if (args.get("--file-mask") != null) {
        const want = args.int("--file-mask", 0);
        used = 0;
        for (0..n) |i| {
            if (want >> @intCast(i) & 1 != 0) {
                files[used] = i;
                used += 1;
            }
        }
        if (used == 0) die("empty --file-mask", .{});
    }
    var r: u64 = 0;
    while (r < rounds) : (r += 1) {
        if (delay_us != 0) _ = c.usleep(@intCast(delay_us));
        if (r % 10 == 9) {
            const modes = [_]c_int{ c.SQLITE_CHECKPOINT_PASSIVE, c.SQLITE_CHECKPOINT_RESTART, c.SQLITE_CHECKPOINT_TRUNCATE };
            _ = c.sqlite3_wal_checkpoint_v2(conn.db, null, if (passive_only) modes[0] else modes[(r / 10) % 3], null, null);
            continue;
        }
        const size = 50 + rand.uintLessThan(u32, 400);
        if (@mod(k, 2) == 1 or used == 1) {
            const f = files[rand.uintLessThan(usize, used)];
            out("try {d} 0\n", .{k});
            autocommitFmt(conn, "insert into {s}.t values ({d}, 0, {d}, 1, randomblob({d}))", .{ Conn.schemaName(f), k, @as(u32, 1) << @intCast(f), size }) catch die("solo {d}", .{k});
            out("ack {d} 0\n", .{k});
        } else {
            var idx: [cwal.max_members]usize = undefined;
            @memcpy(idx[0..used], files[0..used]);
            const count = 2 + rand.uintLessThan(usize, used - 1);
            var mask: u32 = 0;
            for (0..count) |i| {
                const j = i + rand.uintLessThan(usize, used - i);
                std.mem.swap(usize, &idx[i], &idx[j]);
                mask |= @as(u32, 1) << @intCast(idx[i]);
            }
            const txn: u64 = if (mode == .cwal) conn.nextTxn() else @intCast(k);
            out("try {d} {d}\n", .{ k, txn });
            conn.exec("begin") catch die("begin {d}", .{k});
            for (idx[0..count]) |f| {
                execFmt(conn, "insert into {s}.t values ({d}, {d}, {d}, {d}, randomblob({d}))", .{ Conn.schemaName(f), k, txn, mask, count, size }) catch die("multi {d}", .{k});
            }
            conn.commit() catch die("commit {d}", .{k});
            if (mode == .cwal and conn.txn != txn) die("txn {d} committed as {d}", .{ txn, conn.txn });
            out("ack {d} {d}\n", .{ k, txn });
        }
        k += 1;
    }
    conn.close();
    cwal.flushPending();
    out("events={d} tagged={d}\n", .{ cwal.fault.count(), cwal.fault.taggedCount() });
}

// ---------------------------------------------------------------------------
// Transaction semantics (nsem): one scenario per round on an N-file set.
// Every committed transaction k still writes one row of t per file it
// commits, with nwriter's (k, txn, mask, n) columns, so ncheck and the
// crash matrices apply unchanged. The files a transaction commits are the
// files SQLite write-locked, which can exceed the files the scenario wrote
// (BEGIN IMMEDIATE, a statement that failed, a rolled-back savepoint):
// `finish` adds the missing rows before committing.
// ---------------------------------------------------------------------------

const sem_names = [_][]const u8{ "explicit", "solo", "trigger", "trigger-direct", "savepoint", "savepoint-outer", "constraint", "or-rollback", "raise-abort", "raise-rollback", "deferred-fk", "busy", "spill", "immediate", "prepared" };

const Sem = struct {
    conn: *Conn,
    mode: cwal.Mode,
    n: usize,
    k: i64,
    rand: std.Random,
    count: [sem_names.len]u64 = @splat(0),
    /// Insert statements prepared once and reused across commits.
    ins: [cwal.max_members]?*c.sqlite3_stmt = @splat(null),

    /// sqlite3_exec without Conn.exec's error printing; the extended code.
    fn raw(s: *Sem, sql: [:0]const u8) c_int {
        if (c.sqlite3_exec(s.conn.db, sql.ptr, null, null, null) == c.SQLITE_OK) return c.SQLITE_OK;
        return c.sqlite3_extended_errcode(s.conn.db);
    }

    fn rawFmt(s: *Sem, comptime fmt: []const u8, args: anytype) c_int {
        var buf: [8192]u8 = undefined;
        return s.raw(bufPrintZ(&buf, fmt, args) catch unreachable);
    }

    fn ok(s: *Sem, comptime fmt: []const u8, args: anytype) void {
        const rc = s.rawFmt(fmt, args);
        if (rc != c.SQLITE_OK) die("k={d}: " ++ fmt ++ ": {s}", .{s.k} ++ args ++ .{c.sqlite3_errmsg(s.conn.db)});
    }

    fn inTxn(s: *Sem) bool {
        return c.sqlite3_get_autocommit(s.conn.db) == 0;
    }

    fn lockedMask(s: *Sem) u32 {
        var mask: u32 = 0;
        for (0..s.n) |m| {
            if (s.conn.write_locked[m]) mask |= @as(u32, 1) << @intCast(m);
        }
        return mask;
    }

    /// Rows of k in the files of mask (all files: maxInt).
    fn rowsOf(s: *Sem, mask: u32) i64 {
        var total: i64 = 0;
        for (0..s.n) |f| {
            if (mask >> @intCast(f) & 1 == 0) continue;
            var buf: [128]u8 = undefined;
            total += queryInt(s.conn, bufPrintZ(&buf, "select count(*) from {s}.t where k = {d}", .{ Conn.schemaName(f), s.k }) catch unreachable);
        }
        return total;
    }

    fn all(s: *Sem) u32 {
        return @intCast((@as(u64, 1) << @intCast(s.n)) - 1);
    }

    /// A random subset of `count` files (at least 1).
    fn subset(s: *Sem, count: usize) u32 {
        var idx: [cwal.max_members]usize = undefined;
        for (0..s.n) |i| idx[i] = i;
        var mask: u32 = 0;
        for (0..count) |i| {
            const j = i + s.rand.uintLessThan(usize, s.n - i);
            std.mem.swap(usize, &idx[i], &idx[j]);
            mask |= @as(u32, 1) << @intCast(idx[i]);
        }
        return mask;
    }

    fn multi(s: *Sem) u32 {
        return s.subset(2 + s.rand.uintLessThan(usize, s.n - 1));
    }

    fn txnFor(s: *Sem, mask: u32) u64 {
        if (@popCount(mask) < 2) return 0;
        return if (s.mode == .cwal) s.conn.nextTxn() else @intCast(s.k);
    }

    fn insert(s: *Sem, mask: u32, size: u32) void {
        for (0..s.n) |f| {
            if (mask >> @intCast(f) & 1 == 0) continue;
            s.ok("insert into {s}.t values ({d}, 0, 0, 0, randomblob({d}))", .{ Conn.schemaName(f), s.k, size });
        }
    }

    /// Give every write-locked file its row of k with the final txn, mask
    /// and file count, then commit. Returns the commit's error code.
    fn finish(s: *Sem) c_int {
        const mask = s.lockedMask();
        if (mask == 0) die("k={d}: nothing write-locked", .{s.k});
        const cnt = @popCount(mask);
        const txn = s.txnFor(mask);
        for (0..s.n) |f| {
            if (mask >> @intCast(f) & 1 == 0) continue;
            const schema = Conn.schemaName(f);
            s.ok("insert or ignore into {s}.t values ({d}, 0, 0, 0, randomblob(64))", .{ schema, s.k });
            s.ok("update {s}.t set txn = {d}, mask = {d}, n = {d} where k = {d}", .{ schema, txn, mask, cnt, s.k });
        }
        out("try {d} {d}\n", .{ s.k, txn });
        s.conn.commit() catch return c.sqlite3_extended_errcode(s.conn.db);
        if (s.mode == .cwal and txn != 0 and s.conn.txn != txn) die("k={d}: txn {d} committed as {d}", .{ s.k, txn, s.conn.txn });
        out("ack {d} {d}\n", .{ s.k, txn });
        s.k += 1;
        return c.SQLITE_OK;
    }

    fn finishOk(s: *Sem) void {
        const rc = s.finish();
        if (rc != c.SQLITE_OK) die("k={d}: commit: {s}", .{ s.k, c.sqlite3_errstr(rc) });
    }

    /// TEMP trigger on temp.fan writing one row of k to each file of mask,
    /// then optionally raising: fail = 1 aborts the statement, 2 rolls back
    /// the transaction. Only the files it names are write-locked.
    fn fanTrigger(s: *Sem, mask: u32) void {
        var buf: [8192]u8 = undefined;
        var len = (std.fmt.bufPrint(&buf, "create temp trigger fan_out after insert on temp.fan begin ", .{}) catch unreachable).len;
        for (0..s.n) |f| {
            if (mask >> @intCast(f) & 1 == 0) continue;
            len += (std.fmt.bufPrint(buf[len..], "insert into {s}.t values (new.k, new.txn, new.mask, new.n, randomblob(new.size)); ", .{Conn.schemaName(f)}) catch unreachable).len;
        }
        const sql = bufPrintZ(buf[len..], "select raise(abort, 'fan abort') where new.fail = 1; select raise(rollback, 'fan rollback') where new.fail = 2; end", .{}) catch unreachable;
        s.ok("drop trigger if exists temp.fan_out", .{});
        if (s.raw(buf[0 .. len + sql.len :0]) != c.SQLITE_OK) die("fan trigger: {s}", .{c.sqlite3_errmsg(s.conn.db)});
    }

    fn fanSql(s: *Sem, buf: []u8, mask: u32, txn: u64, fail: u32) [:0]u8 {
        return bufPrintZ(buf, "insert into temp.fan values ({d}, {d}, {d}, {d}, {d}, {d})", .{ s.k, txn, mask, @popCount(mask), 100 + s.rand.uintLessThan(u32, 300), fail }) catch unreachable;
    }

    fn expectNone(s: *Sem, what: []const u8) void {
        if (s.inTxn()) die("k={d} {s}: transaction still open", .{ s.k, what });
        const rows = s.rowsOf(s.all());
        if (rows != 0) die("k={d} {s}: {d} rows left", .{ s.k, what, rows });
    }

    fn run(s: *Sem, scenario: usize) void {
        s.count[scenario] += 1;
        switch (scenario) {
            // BEGIN, writes to a random subset, COMMIT.
            0 => {
                s.ok("begin", .{});
                s.insert(s.multi(), 100 + s.rand.uintLessThan(u32, 300));
                s.finishOk();
            },
            // Implicit single-file transaction (autocommit statement).
            1 => {
                const f = s.rand.uintLessThan(usize, s.n);
                out("try {d} 0\n", .{s.k});
                s.ok("insert into {s}.t values ({d}, 0, {d}, 1, randomblob(200))", .{ Conn.schemaName(f), s.k, @as(u32, 1) << @intCast(f) });
                out("ack {d} 0\n", .{s.k});
                s.k += 1;
            },
            // One statement whose TEMP trigger writes several files, run as
            // its own transaction through Conn.autocommit.
            2 => {
                const mask = s.multi();
                s.fanTrigger(mask);
                const txn = s.txnFor(mask);
                var buf: [256]u8 = undefined;
                out("try {d} {d}\n", .{ s.k, txn });
                s.conn.autocommit(s.fanSql(&buf, mask, txn, 0)) catch die("k={d}: trigger autocommit", .{s.k});
                if (s.mode == .cwal and s.conn.txn != txn) die("k={d}: txn {d} committed as {d}", .{ s.k, txn, s.conn.txn });
                out("ack {d} {d}\n", .{ s.k, txn });
                s.k += 1;
            },
            // The same statement issued as a plain autocommit statement: it
            // would commit several files without markers, so CWAL refuses it.
            3 => {
                const mask = s.multi();
                s.fanTrigger(mask);
                const txn: u64 = if (s.mode == .cwal) 0 else @intCast(s.k);
                var buf: [256]u8 = undefined;
                const rc = s.raw(s.fanSql(&buf, mask, txn, 0));
                if (s.mode == .cwal) {
                    if (rc != c.SQLITE_CONSTRAINT_COMMITHOOK) die("k={d}: cross-file autocommit not refused ({s})", .{ s.k, c.sqlite3_errstr(rc) });
                    s.expectNone("refused autocommit");
                } else {
                    if (rc != c.SQLITE_OK) die("k={d}: plain autocommit: {s}", .{ s.k, c.sqlite3_errstr(rc) });
                    out("ack {d} {d}\n", .{ s.k, txn });
                    s.k += 1;
                }
            },
            // Nested savepoints: roll back the inner one (its files stay
            // write-locked), write elsewhere, release both, commit.
            4 => {
                const a = s.subset(1);
                const b = s.subset(1 + s.rand.uintLessThan(usize, s.n - 1)) & ~a;
                s.ok("begin", .{});
                s.ok("savepoint a", .{});
                s.insert(a, 150);
                s.ok("savepoint b", .{});
                s.insert(b, 150);
                s.ok("rollback to b", .{});
                if (s.rowsOf(b) != 0) die("k={d}: rollback to savepoint kept rows", .{s.k});
                if (s.rowsOf(a) != @popCount(a)) die("k={d}: rollback to savepoint lost the outer rows", .{s.k});
                const outer = s.rand.boolean();
                if (outer) {
                    // Roll back the outer savepoint too (which discards b)
                    // and start over.
                    s.ok("rollback to a", .{});
                    if (s.rowsOf(s.all()) != 0) die("k={d}: rollback to outer savepoint kept rows", .{s.k});
                }
                s.insert(s.subset(1) & ~a, 150);
                if (!outer) s.ok("release b", .{});
                s.ok("release a", .{});
                s.finishOk();
            },
            // A savepoint outside BEGIN starts the transaction; RELEASE would
            // commit it without markers (refused in CWAL); COMMIT through
            // Conn.commit works.
            5 => {
                const mask = s.multi();
                s.ok("savepoint outer_sp", .{});
                s.insert(mask, 120);
                if (s.mode == .cwal) {
                    const rc = s.raw("release outer_sp");
                    if (rc != c.SQLITE_CONSTRAINT_COMMITHOOK) die("k={d}: cross-file release not refused ({s})", .{ s.k, c.sqlite3_errstr(rc) });
                    // SQLite rolls the data back but leaves the connection in
                    // an empty transaction after a refused RELEASE.
                    if (s.rowsOf(s.all()) != 0) die("k={d}: refused release kept rows", .{s.k});
                    if (s.inTxn()) s.ok("rollback", .{});
                    s.expectNone("refused release");
                    s.ok("savepoint outer_sp", .{});
                    s.insert(mask, 120);
                }
                s.finishOk();
            },
            // A statement that fails a constraint rolls back only itself.
            6 => {
                const mask = s.multi();
                s.ok("begin", .{});
                s.insert(mask, 100);
                const f = @ctz(mask);
                const rc = s.rawFmt("insert into {s}.t values ({d}, 0, 0, 0, null)", .{ Conn.schemaName(f), s.k });
                if (rc != c.SQLITE_CONSTRAINT_PRIMARYKEY) die("k={d}: duplicate key: {s}", .{ s.k, c.sqlite3_errstr(rc) });
                if (!s.inTxn() or s.rowsOf(mask) != @popCount(mask)) die("k={d}: failed statement undid the transaction", .{s.k});
                // A statement that fails after inserting a row, in a file the
                // transaction had not written: the row is undone but the file
                // stays write-locked, so the commit includes it.
                if (mask != s.all()) {
                    const x: usize = @ctz(~mask);
                    const rc2 = s.rawFmt("insert into {s}.t values ({d}, 0, 0, 0, null), ({d}, 0, 0, 0, null)", .{ Conn.schemaName(x), s.k, s.k });
                    if (rc2 != c.SQLITE_CONSTRAINT_PRIMARYKEY) die("k={d}: duplicate rows: {s}", .{ s.k, c.sqlite3_errstr(rc2) });
                    if (s.rowsOf(@as(u32, 1) << @intCast(x)) != 0) die("k={d}: failed statement kept a row", .{s.k});
                    if (s.lockedMask() & (@as(u32, 1) << @intCast(x)) == 0) die("k={d}: failed statement left no lock", .{s.k});
                }
                s.finishOk();
            },
            // ON CONFLICT ROLLBACK ends the whole transaction.
            7 => {
                const mask = s.multi();
                s.ok("begin", .{});
                s.insert(mask, 100);
                const rc = s.rawFmt("insert or rollback into {s}.t values ({d}, 0, 0, 0, null)", .{ Conn.schemaName(@ctz(mask)), s.k });
                if (rc != c.SQLITE_CONSTRAINT_PRIMARYKEY) die("k={d}: or rollback: {s}", .{ s.k, c.sqlite3_errstr(rc) });
                s.expectNone("or rollback");
            },
            // A trigger raises ABORT after writing several files: the
            // statement is undone in every file, the transaction continues.
            8 => {
                const mask = s.multi();
                s.fanTrigger(mask);
                var buf: [256]u8 = undefined;
                s.ok("begin", .{});
                const rc = s.raw(s.fanSql(&buf, mask, 0, 1));
                if (rc & 0xff != c.SQLITE_CONSTRAINT) die("k={d}: raise abort: {s}", .{ s.k, c.sqlite3_errstr(rc) });
                if (!s.inTxn() or s.rowsOf(s.all()) != 0) die("k={d}: raise(abort) left rows or ended the transaction", .{s.k});
                s.ok("{s}", .{s.fanSql(&buf, mask, 0, 0)});
                s.finishOk();
            },
            // A trigger raises ROLLBACK: the whole transaction ends.
            9 => {
                const mask = s.multi();
                s.fanTrigger(mask);
                var buf: [256]u8 = undefined;
                s.ok("begin", .{});
                s.insert(s.subset(1) & ~mask, 100);
                const rc = s.raw(s.fanSql(&buf, mask, 0, 2));
                if (rc & 0xff != c.SQLITE_CONSTRAINT) die("k={d}: raise rollback: {s}", .{ s.k, c.sqlite3_errstr(rc) });
                s.expectNone("raise(rollback)");
            },
            // COMMIT fails on a deferred foreign key and leaves the
            // transaction open; fix it and commit again (a new number).
            10 => {
                s.ok("begin", .{});
                s.insert(s.multi() | 1, 100);
                s.ok("insert into main.fkc values ({d}, {d})", .{ s.k, -s.k });
                const rc = s.finish();
                if (rc != c.SQLITE_CONSTRAINT_FOREIGNKEY) die("k={d}: deferred fk commit: {s}", .{ s.k, c.sqlite3_errstr(rc) });
                if (!s.inTxn()) die("k={d}: failed commit ended the transaction", .{s.k});
                s.ok("insert into main.fkp values ({d})", .{-s.k});
                s.finishOk();
            },
            // SQLITE_BUSY: another connection holds one file's write lock;
            // the statement fails, the transaction stays open; retry once the
            // lock is free, or give up and roll back.
            11 => {
                const mask = s.multi();
                const f: usize = @ctz(mask);
                var blocker: ?*c.sqlite3 = null;
                var path: [max_path]u8 = undefined;
                const name = c.sqlite3_db_filename(s.conn.db, Conn.schemaName(f));
                const z = bufPrintZ(&path, "{s}", .{std.mem.span(name)}) catch unreachable;
                if (c.sqlite3_open_v2(z.ptr, &blocker, c.SQLITE_OPEN_READWRITE, "unix") != c.SQLITE_OK) die("blocker open", .{});
                _ = c.sqlite3_db_config(blocker, c.SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, @as(c_int, 1), @as(?*c_int, null));
                if (c.sqlite3_exec(blocker, "begin immediate", null, null, null) != c.SQLITE_OK) die("blocker begin: {s}", .{c.sqlite3_errmsg(blocker)});
                _ = c.sqlite3_busy_timeout(s.conn.db, 20);
                s.ok("begin", .{});
                s.insert(mask & ~(@as(u32, 1) << @intCast(f)), 100);
                const rc = s.rawFmt("insert into {s}.t values ({d}, 0, 0, 0, randomblob(100))", .{ Conn.schemaName(f), s.k });
                if (rc & 0xff != c.SQLITE_BUSY) die("k={d}: expected busy, got {s}", .{ s.k, c.sqlite3_errstr(rc) });
                if (!s.inTxn()) die("k={d}: busy ended the transaction", .{s.k});
                _ = c.sqlite3_exec(blocker, "rollback", null, null, null);
                _ = c.sqlite3_close(blocker);
                _ = c.sqlite3_busy_timeout(s.conn.db, 10_000);
                if (s.rand.boolean()) {
                    s.ok("rollback", .{});
                    s.expectNone("rollback after busy");
                } else {
                    s.insert(@as(u32, 1) << @intCast(f), 100);
                    s.finishOk();
                }
            },
            // Larger than the page cache: SQLite spills uncommitted frames
            // into every WAL before the commit.
            12 => {
                s.ok("begin", .{});
                s.insert(s.multi(), 30_000 + s.rand.uintLessThan(u32, 20_000));
                s.finishOk();
            },
            // BEGIN IMMEDIATE write-locks every file, so the transaction
            // commits (a marker) in every file whatever it writes.
            13 => {
                s.ok("begin immediate", .{});
                if (s.lockedMask() != s.all()) die("k={d}: begin immediate locked {d}", .{ s.k, s.lockedMask() });
                s.insert(s.subset(1), 100);
                s.finishOk();
            },
            // Prepared statements reused across commits, and a read
            // statement left mid-step across the commit.
            else => {
                const mask = s.multi();
                var sel: ?*c.sqlite3_stmt = null;
                if (c.sqlite3_prepare_v2(s.conn.db, "select k from main.t", -1, &sel, null) != c.SQLITE_OK) die("prepare select", .{});
                defer _ = c.sqlite3_finalize(sel);
                s.ok("begin", .{});
                _ = c.sqlite3_step(sel);
                for (0..s.n) |f| {
                    if (mask >> @intCast(f) & 1 == 0) continue;
                    const st = s.ins[f].?;
                    _ = c.sqlite3_bind_int64(st, 1, s.k);
                    if (c.sqlite3_step(st) != c.SQLITE_DONE) die("k={d}: prepared insert: {s}", .{ s.k, c.sqlite3_errmsg(s.conn.db) });
                    _ = c.sqlite3_reset(st);
                }
                s.finishOk();
            },
        }
    }
};

/// Section 2 workload: --rounds rounds, round r runs scenario r % 16 (15 is
/// a checkpoint). Prints try/ack lines like nwriter, then the per-scenario
/// counts.
fn cmdNSem(dir: []const u8, args: Args) void {
    const mode = args.mode();
    const n = nFiles(args);
    const rounds = args.int("--rounds", 32);
    const conn = openN(dir, n, .{ .mode = mode, .role = .writer, .cache_pages = 10 }) catch |err| {
        out("writer-open-error {s}\n", .{@errorName(err)});
        cwal.flushPending();
        c.exit(if (err == error.Broken) 3 else 2);
    };
    var buf: [8192]u8 = undefined;
    const k = queryInt(conn, unionSql(&buf, n, "select coalesce(max(k), 0) from u")) + 1;
    var prng = std.Random.DefaultPrng.init(args.int("--seed", 1) *% 0x9e3779b97f4a7c15 +% @as(u64, @intCast(k)));
    var s: Sem = .{ .conn = conn, .mode = mode, .n = n, .k = k, .rand = prng.random() };
    // Per-file audit trigger (a trigger write inside each file's commit)
    // and the deferred foreign key, created by one cross-file DDL
    // transaction. It also commits a row of k to every file, like any other
    // cross-file commit, so ncheck can match its marker to data.
    s.ok("pragma foreign_keys = on", .{});
    s.ok("begin immediate", .{});
    for (0..n) |f| {
        const schema = Conn.schemaName(f);
        s.ok("create table if not exists {s}.audit(k integer primary key)", .{schema});
        s.ok("create trigger if not exists {s}.t_audit after insert on t begin insert into audit values (new.k); end", .{schema});
    }
    s.ok("create table if not exists main.fkp(id integer primary key)", .{});
    s.ok("create table if not exists main.fkc(id integer primary key, pid integer references fkp(id) deferrable initially deferred)", .{});
    s.finishOk();
    s.ok("create temp table fan(k, txn, mask, n, size, fail)", .{});
    for (0..n) |f| {
        const sql = bufPrintZ(&buf, "insert into {s}.t values (?1, 0, 0, 0, randomblob(80))", .{Conn.schemaName(f)}) catch unreachable;
        if (c.sqlite3_prepare_v2(conn.db, sql.ptr, -1, &s.ins[f], null) != c.SQLITE_OK) die("prepare insert", .{});
    }
    const passive_only = std.mem.eql(u8, args.get("--ckpt") orelse "all", "passive");
    const delay_us = args.int("--delay-us", 0);
    var r: u64 = 0;
    while (r < rounds) : (r += 1) {
        if (delay_us != 0) _ = c.usleep(@intCast(delay_us));
        const scenario = r % (sem_names.len + 1);
        if (scenario == sem_names.len) {
            // A commit that writes only TEMP reaches the commit hook but no
            // member's phase two; it must not leave the writer unable to
            // checkpoint.
            s.ok("delete from temp.fan", .{});
            const modes = [_]c_int{ c.SQLITE_CHECKPOINT_PASSIVE, c.SQLITE_CHECKPOINT_RESTART, c.SQLITE_CHECKPOINT_TRUNCATE };
            const denied = conn.stats.checkpoint_denied;
            _ = c.sqlite3_wal_checkpoint_v2(conn.db, null, if (passive_only) modes[0] else modes[(r / sem_names.len) % 3], null, null);
            if (conn.stats.checkpoint_denied != denied) die("k={d}: writer checkpoint denied after a temp-only commit", .{s.k});
            continue;
        }
        s.run(scenario);
    }
    for (s.ins[0..n]) |st| _ = c.sqlite3_finalize(st);
    conn.close();
    cwal.flushPending();
    var line: [1024]u8 = undefined;
    var len: usize = 0;
    for (sem_names, s.count) |name, cnt| {
        if (cnt != 0) len += (std.fmt.bufPrint(line[len..], " {s}={d}", .{ name, cnt }) catch unreachable).len;
    }
    out("sem ok{s}\n", .{line[0..len]});
    out("events={d} tagged={d}\n", .{ cwal.fault.count(), cwal.fault.taggedCount() });
}

fn readWhole(path: []const u8) []u8 {
    var pbuf: [max_path]u8 = undefined;
    const z = bufPrintZ(&pbuf, "{s}", .{path}) catch die("path", .{});
    const fd = c.open(z.ptr, c.O_RDONLY);
    if (fd < 0) die("open {s}", .{path});
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) die("stat {s}", .{path});
    if (st.st_size == 0) return &.{};
    const data = std.heap.c_allocator.alloc(u8, @intCast(st.st_size)) catch die("oom", .{});
    if (c.pread(fd, data.ptr, data.len, 0) != data.len) die("read {s}", .{path});
    return data;
}

/// Integrity, per-transaction agreement across files, the prefix property,
/// unique marker numbers, markers that match the data, and (with
/// --acked-file, lines "k txn") that every acknowledged commit survived.
fn cmdNCheck(dir: []const u8, args: Args) void {
    const mode = args.mode();
    const n = nFiles(args);
    const conn = openN(dir, n, .{ .mode = mode, .role = .writer }) catch |err| die("open {s}", .{@errorName(err)});
    var buf: [8192]u8 = undefined;
    var text: [256]u8 = undefined;
    for (0..n) |i| {
        const result = queryText(conn, bufPrintZ(&buf, "pragma {s}.integrity_check", .{Conn.schemaName(i)}) catch unreachable, &text);
        if (!std.mem.eql(u8, result, "ok")) die("integrity {s}: {s}", .{ Conn.schemaName(i), result });
    }
    const st = nState(conn, n);
    if (st.bad != 0) die("torn transactions={d}", .{st.bad});
    if (st.distinct != st.max_k) die("not a prefix distinct={d} max={d}", .{ st.distinct, st.max_k });
    if (st.shared_txn != 0) die("marker numbers shared={d}", .{st.shared_txn});
    if (mode == .cwal) {
        for (0..n) |i| {
            const schema = Conn.schemaName(i);
            var marker: [2]i64 = undefined;
            queryRow(conn, bufPrintZ(&buf, "select txn, mask from {s}.cwal_marker where k = 0", .{schema}) catch unreachable, &marker);
            var data: [2]i64 = undefined;
            queryRow(conn, bufPrintZ(&buf, "select coalesce(max(txn), 0), coalesce((select mask from {s}.t where txn > 0 order by txn desc limit 1), 0) from {s}.t", .{ schema, schema }) catch unreachable, &data);
            if (marker[0] != data[0] or marker[1] != data[1]) die("{s} marker {d}/{d} data {d}/{d}", .{ schema, marker[0], marker[1], data[0], data[1] });
        }
    }
    // nsem's per-file audit trigger writes inside the same commit as t;
    // one cross-file DDL transaction created every audit table.
    var audits: usize = 0;
    for (0..n) |i| {
        const schema = Conn.schemaName(i);
        if (queryInt(conn, bufPrintZ(&buf, "select count(*) from {s}.sqlite_schema where name = 'audit'", .{schema}) catch unreachable) == 0) continue;
        audits += 1;
        const diff = queryInt(conn, bufPrintZ(&buf, "select (select count(*) from (select k from {s}.t except select k from {s}.audit)) + (select count(*) from (select k from {s}.audit except select k from {s}.t))", .{ schema, schema, schema, schema }) catch unreachable);
        if (diff != 0) die("{s} audit differs from t in {d} keys", .{ schema, diff });
    }
    if (audits != 0 and audits != n) die("torn schema: {d} of {d} files have audit", .{ audits, n });
    var acked: u64 = 0;
    if (args.get("--acked-file")) |path| {
        const data = readWhole(path);
        var lines = std.mem.tokenizeScalar(u8, data, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            const k = std.fmt.parseInt(i64, fields.next() orelse continue, 10) catch die("acked line {s}", .{line});
            const txn = std.fmt.parseInt(i64, fields.next() orelse die("acked line {s}", .{line}), 10) catch die("acked line {s}", .{line});
            var q: [8192]u8 = undefined;
            const sql = unionSql(&q, n, "select count(*) from u where k = ?1 and txn = ?2");
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(conn.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) die("prepare acked", .{});
            _ = c.sqlite3_bind_int64(stmt, 1, k);
            _ = c.sqlite3_bind_int64(stmt, 2, txn);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) die("step acked", .{});
            const found = c.sqlite3_column_int64(stmt, 0);
            _ = c.sqlite3_finalize(stmt);
            if (found == 0) die("lost acked k={d} txn={d}", .{ k, txn });
            acked += 1;
        }
    }
    conn.close();
    out("check ok txns={d} acked={d} recovery={s}\n", .{ st.max_k, acked, cwal.last_recovery });
}

// ---------------------------------------------------------------------------
// check / recover
// ---------------------------------------------------------------------------

fn cmdCheck(dir: []const u8, args: Args) void {
    const mode = args.mode();
    const conn = openSet(dir, .{ .mode = mode, .role = .writer }) catch |err| die("open {s}", .{@errorName(err)});
    var buf: [256]u8 = undefined;
    for ([_][:0]const u8{ "pragma main.integrity_check", "pragma m1.integrity_check" }) |sql| {
        const result = queryText(conn, sql, &buf);
        if (!std.mem.eql(u8, result, "ok")) die("{s}: {s}", .{ sql, result });
    }
    const n_main = queryInt(conn, "select count(*) from main.pairs");
    const max_main = queryInt(conn, "select coalesce(max(id), 0) from main.pairs");
    const n_store = queryInt(conn, "select count(*) from pairs_s");
    const max_store = queryInt(conn, "select coalesce(max(id), 0) from pairs_s");
    const joined = queryInt(conn, "select count(*) from main.pairs join pairs_s using (id)");
    if (n_main != max_main or n_store != max_store) die("pair ids not a prefix main={d}/{d} store={d}/{d}", .{ n_main, max_main, n_store, max_store });
    if (n_main != n_store or joined != n_main) die("torn pairs main={d} store={d}", .{ n_main, n_store });
    const bulk_main = queryInt(conn, "select count(*) from main.bulk");
    const bulk_store = queryInt(conn, "select count(*) from bulk_s");
    const bad_groups = queryInt(conn, std.fmt.comptimePrint("select count(*) from (select pid from main.bulk group by pid having count(*) != {d})", .{bulk_rows}));
    if (bulk_main != bulk_store or bad_groups != 0) die("torn bulk main={d} store={d} bad={d}", .{ bulk_main, bulk_store, bad_groups });
    const acked_pair: i64 = @intCast(args.int("--acked-pair", 0));
    const acked_solo: i64 = @intCast(args.int("--acked-solo", 0));
    const acked_solos: i64 = @intCast(args.int("--acked-solos", 0));
    if (max_main < acked_pair) die("lost acked pair {d} (have {d})", .{ acked_pair, max_main });
    if (queryInt(conn, "select coalesce(max(id), 0) from main.solo") < acked_solo) die("lost acked solo {d}", .{acked_solo});
    if (queryInt(conn, "select coalesce(max(id), 0) from solo_s") < acked_solos) die("lost acked solos {d}", .{acked_solos});
    conn.close();
    out("check ok pairs={d} recovery={s}\n", .{ n_main, cwal.last_recovery });
}

fn cmdRecover(dir: []const u8, args: Args) void {
    const options: cwal.Options = .{ .mode = args.mode(), .role = .reader };
    const opened = if (args.get("--files") != null) openN(dir, nFiles(args), options) else openSet(dir, options);
    const conn = opened catch |err| {
        out("recover-open-error {s}\n", .{@errorName(err)});
        c.exit(2);
    };
    conn.close();
    cwal.flushPending();
    out("events={d}\n", .{cwal.fault.count()});
}

fn cmdState(dir: []const u8) void {
    // Report the seqlock page without opening the set (no recovery).
    var buf: [max_path]u8 = undefined;
    const path = bufPrintZ(&buf, "{s}/main.db-cwal-snap", .{dir}) catch unreachable;
    const fd = c.open(path.ptr, c.O_RDONLY);
    if (fd < 0) {
        out("state none\n", .{});
        return;
    }
    defer _ = c.close(fd);
    var b: [24]u8 = undefined;
    if (c.pread(fd, &b, b.len, 0) != b.len) die("read {s}", .{path});
    const ckpt = std.mem.readInt(u64, b[16..24], .native);
    out("state seq={d} cross={d} broken={d} ckpt_active={d} ckpt_started={d}\n", .{
        std.mem.readInt(u64, b[0..8], .native),   std.mem.readInt(u32, b[8..12], .native),
        std.mem.readInt(u32, b[12..16], .native), @as(u32, @truncate(ckpt)),
        ckpt >> 32,
    });
}

// ---------------------------------------------------------------------------
// readers
// ---------------------------------------------------------------------------

const ReaderStats = struct {
    reads: u64 = 0,
    mixed: u64 = 0,
    broken: u64 = 0,
    reopen: u64 = 0,
    ckpt_attempts: u64 = 0,
    ckpt_denied: u64 = 0,
    snapshot_reads: u64 = 0,
    seq_retries: u64 = 0,
    snapshot_waits: u64 = 0,
    ckpt_races: u64 = 0,
    ckpt_fallbacks: u64 = 0,
    ckpt_violations: u64 = 0,
};

const ReaderJob = struct {
    dir: []const u8,
    mode: cwal.Mode,
    deadline_ns: u64,
    gap_us: u32,
    /// Test: stay inside each read this long before checking it.
    hold_us: u32,
    seed: u64,
    /// The writer has not crashed, so every solo commit on main.db is
    /// followed by one on store.db: a snapshot has solo_s == solo or
    /// solo_s + 1 == solo.
    solo_order: bool,
    /// N-file set size, or 0 for the two-file set.
    nfiles: usize = 0,
    stats: ReaderStats = .{},
};

fn openReader(job: *ReaderJob) ?*Conn {
    while (cwal.monotonicNs() < job.deadline_ns) {
        const options: cwal.Options = .{ .mode = job.mode, .role = .reader };
        if (if (job.nfiles != 0) openN(job.dir, job.nfiles, options) else openSet(job.dir, options)) |conn| {
            return conn;
        } else |err| {
            if (err != error.Broken and err != error.Sqlite) die("reader open {s}", .{@errorName(err)});
            job.stats.broken += 1;
            _ = c.usleep(@intCast(1000 + job.seed % 4000));
            job.seed = job.seed *% 6364136223846793005 +% 1442695040888963407;
        }
    }
    return null;
}

fn closeReader(job: *ReaderJob, conn: *Conn) void {
    job.stats.snapshot_reads += conn.stats.snapshot_reads;
    job.stats.seq_retries += conn.stats.seq_retries;
    job.stats.snapshot_waits += conn.stats.snapshot_waits;
    job.stats.ckpt_races += conn.stats.ckpt_races;
    job.stats.ckpt_fallbacks += conn.stats.ckpt_fallbacks;
    conn.close();
}

fn readerThread(job: *ReaderJob) void {
    var conn = openReader(job) orelse return;
    var iteration: u64 = 0;
    while (cwal.monotonicNs() < job.deadline_ns) : (iteration += 1) {
        conn.beginRead(job.gap_us) catch |err| {
            if (err != error.Broken and err != error.Sqlite) die("beginRead {s}", .{@errorName(err)});
            job.stats.broken += 1;
            // An application may still request a checkpoint here.
            _ = c.sqlite3_wal_checkpoint_v2(conn.db, null, c.SQLITE_CHECKPOINT_PASSIVE, null, null);
            closeReader(job, conn);
            conn = openReader(job) orelse return;
            continue;
        };
        // Read, hold the transaction (test), check the snapshot, end it.
        var mixed = false;
        if (job.nfiles != 0) {
            const st = nState(conn, job.nfiles);
            mixed = st.bad != 0 or st.distinct != st.max_k or st.shared_txn != 0;
            if (mixed and job.stats.mixed < 3) out("MIXED torn={d} distinct={d} max={d} shared={d}\n", .{ st.bad, st.distinct, st.max_k, st.shared_txn });
            if (job.hold_us != 0) {
                // A long-lived read transaction must keep its snapshot
                // while the writer commits and checkpoints.
                _ = c.usleep(job.hold_us);
                const again = nState(conn, job.nfiles);
                if (!std.meta.eql(st, again)) {
                    if (job.stats.mixed < 3) out("MIXED snapshot moved max {d}->{d} distinct {d}->{d}\n", .{ st.max_k, again.max_k, st.distinct, again.distinct });
                    mixed = true;
                }
            }
        } else {
            const a = queryInt(conn, "select count(*) from main.pairs");
            const b = queryInt(conn, "select count(*) from pairs_s");
            const ba = queryInt(conn, "select count(*) from main.bulk");
            const bb = queryInt(conn, "select count(*) from bulk_s");
            const sa = queryInt(conn, "select count(*) from main.solo");
            const sb = queryInt(conn, "select count(*) from solo_s");
            mixed = a != b or ba != bb or (job.solo_order and sb != sa and sb + 1 != sa);
            if (mixed and job.stats.mixed < 3) out("MIXED pairs {d}/{d} bulk {d}/{d} solo {d}/{d}\n", .{ a, b, ba, bb, sa, sb });
        }
        if (job.hold_us != 0 and job.nfiles == 0) _ = c.usleep(job.hold_us);
        if (!conn.snapshotIntact()) job.stats.ckpt_violations += 1;
        conn.exec("rollback") catch {};
        job.stats.reads += 1;
        if (mixed) job.stats.mixed += 1;
        if (iteration % 25 == 24) {
            // Readers must never copy frames into a database file.
            job.stats.ckpt_attempts += 1;
            const before = conn.stats.checkpoint_denied;
            _ = c.sqlite3_wal_checkpoint_v2(conn.db, null, c.SQLITE_CHECKPOINT_PASSIVE, null, null);
            if (conn.stats.checkpoint_denied != before) job.stats.ckpt_denied += 1;
        }
        if (iteration % 100 == 99) {
            // Closing a read-write connection attempts a checkpoint.
            job.stats.reopen += 1;
            closeReader(job, conn);
            conn = openReader(job) orelse return;
        }
    }
    closeReader(job, conn);
}

fn cmdReader(dir: []const u8, args: Args) void {
    const threads = args.int("--threads", 2);
    const duration_ms = args.int("--duration-ms", 1000);
    var jobs: [16]ReaderJob = undefined;
    var handles: [16]std.Thread = undefined;
    const deadline = cwal.monotonicNs() + duration_ms * 1_000_000;
    for (0..threads) |i| {
        jobs[i] = .{ .dir = dir, .mode = args.mode(), .deadline_ns = deadline, .gap_us = @intCast(args.int("--gap-us", 0)), .hold_us = @intCast(args.int("--hold-us", 0)), .seed = i * 7919 + @as(u64, @intCast(c.getpid())), .solo_order = args.int("--solo-order", 0) != 0, .nfiles = if (args.get("--files") != null) nFiles(args) else 0 };
        handles[i] = std.Thread.spawn(.{}, readerThread, .{&jobs[i]}) catch die("spawn", .{});
    }
    var total: ReaderStats = .{};
    for (0..threads) |i| {
        handles[i].join();
        inline for (comptime std.meta.fieldNames(ReaderStats)) |name| @field(total, name) += @field(jobs[i].stats, name);
    }
    out("reader reads={d} mixed={d} broken={d} reopen={d} ckpt_attempts={d} ckpt_denied={d} snapshot_reads={d} seq_retries={d} snapshot_waits={d} ckpt_races={d} ckpt_fallbacks={d} ckpt_violations={d}\n", .{ total.reads, total.mixed, total.broken, total.reopen, total.ckpt_attempts, total.ckpt_denied, total.snapshot_reads, total.seq_retries, total.snapshot_waits, total.ckpt_races, total.ckpt_fallbacks, total.ckpt_violations });
    c.exit(if (total.mixed != 0 or total.ckpt_violations != 0) 1 else 0);
}

// ---------------------------------------------------------------------------
// benchmarks
// ---------------------------------------------------------------------------

fn cmdBench(dir: []const u8, args: Args) void {
    const mode = args.mode();
    const commits = args.int("--commits", 500);
    const sync = args.get("--sync") orelse "FULL";
    var sync_buf: [16]u8 = undefined;
    const sync_z = bufPrintZ(&sync_buf, "{s}", .{sync}) catch unreachable;
    const pair = std.mem.eql(u8, args.get("--kind") orelse "pair", "pair");
    const conn = openSet(dir, .{ .mode = mode, .role = .writer, .synchronous = sync_z }) catch die("open", .{});
    installTriggers(conn) catch die("triggers", .{});
    const samples = std.heap.c_allocator.alloc(u64, commits) catch die("oom", .{});
    const syncs_before = cwal.fault.syncs;
    var id = queryInt(conn, "select coalesce(max(id), 0) from main.pairs") + 1;
    var solo = queryInt(conn, "select coalesce(max(id), 0) from main.solo") + 1;
    for (samples) |*s| {
        const start = cwal.monotonicNs();
        if (pair) {
            autocommitFmt(conn, "insert into main.pairs values ({d}, randomblob(100))", .{id}) catch die("insert", .{});
            id += 1;
        } else {
            execFmt(conn, "insert into main.solo values ({d}, randomblob(100))", .{solo}) catch die("insert", .{});
            solo += 1;
        }
        s.* = cwal.monotonicNs() - start;
    }
    const syncs = cwal.fault.syncs - syncs_before;
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    var sum: u64 = 0;
    for (samples) |s| sum += s;
    out("bench mode={s} sync={s} kind={s} commits={d} mean_us={d:.1} p50_us={d:.1} p99_us={d:.1} syncs_per_commit={d:.2}\n", .{
        @tagName(mode),                                                           sync,                                                   if (pair) "pair" else "solo",                                  commits,
        @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(commits)) / 1000.0, @as(f64, @floatFromInt(samples[commits / 2])) / 1000.0, @as(f64, @floatFromInt(samples[commits * 99 / 100])) / 1000.0, @as(f64, @floatFromInt(syncs)) / @as(f64, @floatFromInt(commits)),
    });
    conn.close();
}

const RwJob = struct {
    dir: []const u8,
    mode: cwal.Mode,
    deadline_ns: u64,
    count: u64 = 0,
    window_wait_ns: u64 = 0,
    snapshot_reads: u64 = 0,
    seq_retries: u64 = 0,
};

fn rwWriter(job: *RwJob) void {
    const conn = openSet(job.dir, .{ .mode = job.mode, .role = .writer, .synchronous = "FULL" }) catch die("open writer", .{});
    installTriggers(conn) catch die("triggers", .{});
    var id = queryInt(conn, "select coalesce(max(id), 0) from main.pairs") + 1;
    while (cwal.monotonicNs() < job.deadline_ns) {
        autocommitFmt(conn, "insert into main.pairs values ({d}, randomblob(100))", .{id}) catch die("insert", .{});
        id += 1;
        job.count += 1;
    }
    conn.close();
}

fn rwReader(job: *RwJob) void {
    const conn = openSet(job.dir, .{ .mode = job.mode, .role = .reader }) catch die("open reader", .{});
    while (cwal.monotonicNs() < job.deadline_ns) {
        conn.beginRead(0) catch die("beginRead", .{});
        _ = queryInt(conn, "select coalesce(max(id), 0) from main.pairs");
        _ = queryInt(conn, "select coalesce(max(id), 0) from pairs_s");
        conn.exec("rollback") catch {};
        job.count += 1;
    }
    job.window_wait_ns = conn.stats.window_wait_ns;
    job.snapshot_reads = conn.stats.snapshot_reads;
    job.seq_retries = conn.stats.seq_retries;
    conn.close();
}

fn cmdBenchRw(dir: []const u8, args: Args) void {
    const mode = args.mode();
    const readers = args.int("--readers", 4);
    const duration_ms = args.int("--duration-ms", 2000);
    const deadline = cwal.monotonicNs() + duration_ms * 1_000_000;
    var writer: RwJob = .{ .dir = dir, .mode = mode, .deadline_ns = deadline };
    var jobs: [16]RwJob = undefined;
    var handles: [17]std.Thread = undefined;
    // Open the writer first so it performs any recovery.
    handles[16] = std.Thread.spawn(.{}, rwWriter, .{&writer}) catch die("spawn", .{});
    _ = c.usleep(50_000);
    for (0..readers) |i| {
        jobs[i] = .{ .dir = dir, .mode = mode, .deadline_ns = deadline };
        handles[i] = std.Thread.spawn(.{}, rwReader, .{&jobs[i]}) catch die("spawn", .{});
    }
    var reads: u64 = 0;
    var reader_wait: u64 = 0;
    var snapshot_reads: u64 = 0;
    var seq_retries: u64 = 0;
    for (0..readers) |i| {
        handles[i].join();
        reads += jobs[i].count;
        reader_wait += jobs[i].window_wait_ns;
        snapshot_reads += jobs[i].snapshot_reads;
        seq_retries += jobs[i].seq_retries;
    }
    handles[16].join();
    const seconds = @as(f64, @floatFromInt(duration_ms)) / 1000.0;
    out("benchrw mode={s} readers={d} reads_per_s={d:.0} commits_per_s={d:.0} reader_window_wait_ms={d:.1} snapshot_reads={d} seq_retries={d}\n", .{
        @tagName(mode),                                  readers,                                    @as(f64, @floatFromInt(reads)) / seconds,
        @as(f64, @floatFromInt(writer.count)) / seconds, @as(f64, @floatFromInt(reader_wait)) / 1e6, snapshot_reads,
        seq_retries,
    });
}

// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init.Minimal) void {
    cwal.register();
    const list = init.args.toSlice(std.heap.c_allocator) catch die("args", .{});
    if (list.len < 3) die("usage: cwal <seed|writer|reader|check|recover|state|bench|benchrw|nseed|nwriter|nreader|ncheck> <dir> [options]", .{});
    const args: Args = .{ .list = list };
    const cmd = list[1];
    const dir = list[2];
    if (std.mem.eql(u8, cmd, "seed")) cmdSeed(dir) else if (std.mem.eql(u8, cmd, "writer")) cmdWriter(dir, args) else if (std.mem.eql(u8, cmd, "reader")) cmdReader(dir, args) else if (std.mem.eql(u8, cmd, "check")) cmdCheck(dir, args) else if (std.mem.eql(u8, cmd, "recover")) cmdRecover(dir, args) else if (std.mem.eql(u8, cmd, "state")) cmdState(dir) else if (std.mem.eql(u8, cmd, "bench")) cmdBench(dir, args) else if (std.mem.eql(u8, cmd, "benchrw")) cmdBenchRw(dir, args) else if (std.mem.eql(u8, cmd, "nseed")) cmdNSeed(dir, args) else if (std.mem.eql(u8, cmd, "nwriter")) cmdNWriter(dir, args) else if (std.mem.eql(u8, cmd, "nreader")) cmdReader(dir, args) else if (std.mem.eql(u8, cmd, "ncheck")) cmdNCheck(dir, args) else if (std.mem.eql(u8, cmd, "nsem")) cmdNSem(dir, args) else die("unknown command {s}", .{cmd});
}
