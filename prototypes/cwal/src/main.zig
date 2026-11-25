//! CWAL prototype driver: seeds a two-file set, runs a crashable writer,
//! concurrent readers, recovery and the consistency checker, and benchmarks.
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
// check / recover
// ---------------------------------------------------------------------------

fn cmdCheck(dir: []const u8, args: Args) void {
    const mode = args.mode();
    const conn = openSet(dir, .{ .mode = mode, .role = .writer }) catch |err| die("open {s}", .{@errorName(err)});
    if (mode == .cwal) {
        const state = conn.readJournal().state;
        if (state != .idle and state != .committed) die("journal {s} after open", .{@tagName(state)});
    }
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
    const conn = openSet(dir, .{ .mode = args.mode(), .role = .reader }) catch |err| {
        out("recover-open-error {s}\n", .{@errorName(err)});
        c.exit(2);
    };
    conn.close();
    cwal.flushPending();
    out("events={d}\n", .{cwal.fault.count()});
}

fn cmdState(dir: []const u8) void {
    // Report the journal without opening the set (no recovery).
    var buf: [max_path]u8 = undefined;
    const path = bufPrintZ(&buf, "{s}/main.db-cwal", .{dir}) catch unreachable;
    const fd = c.open(path.ptr, c.O_RDONLY);
    if (fd < 0) {
        out("state none\n", .{});
        return;
    }
    defer _ = c.close(fd);
    var best_seq: u64 = 0;
    var best_state: u32 = 0;
    for (0..2) |slot| {
        var b: [128]u8 = undefined;
        if (c.pread(fd, &b, b.len, @intCast(slot * 4096)) != b.len) continue;
        if (std.mem.readInt(u32, b[0..4], .little) != 0x4357_414c) continue;
        var h: u64 = 0xcbf29ce484222325;
        for (b[0..120]) |x| h = (h ^ x) *% 0x100000001b3;
        if (h != std.mem.readInt(u64, b[120..128], .little)) continue;
        const seq = std.mem.readInt(u64, b[4..12], .little);
        if (seq > best_seq) {
            best_seq = seq;
            best_state = std.mem.readInt(u32, b[12..16], .little);
        }
    }
    const names = [_][]const u8{ "idle", "prepared", "committed", "broken" };
    out("state {s}\n", .{if (best_state < names.len) names[best_state] else "?"});
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
    stats: ReaderStats = .{},
};

fn openReader(job: *ReaderJob) ?*Conn {
    while (cwal.monotonicNs() < job.deadline_ns) {
        if (openSet(job.dir, .{ .mode = job.mode, .role = .reader })) |conn| {
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
        const a = queryInt(conn, "select count(*) from main.pairs");
        const b = queryInt(conn, "select count(*) from pairs_s");
        const ba = queryInt(conn, "select count(*) from main.bulk");
        const bb = queryInt(conn, "select count(*) from bulk_s");
        const sa = queryInt(conn, "select count(*) from main.solo");
        const sb = queryInt(conn, "select count(*) from solo_s");
        if (job.hold_us != 0) _ = c.usleep(job.hold_us);
        if (!conn.snapshotIntact()) job.stats.ckpt_violations += 1;
        conn.exec("rollback") catch {};
        job.stats.reads += 1;
        if (a != b or ba != bb or (job.solo_order and sb != sa and sb + 1 != sa)) {
            job.stats.mixed += 1;
            if (job.stats.mixed <= 3) out("MIXED pairs {d}/{d} bulk {d}/{d} solo {d}/{d}\n", .{ a, b, ba, bb, sa, sb });
        }
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
        jobs[i] = .{ .dir = dir, .mode = args.mode(), .deadline_ns = deadline, .gap_us = @intCast(args.int("--gap-us", 0)), .hold_us = @intCast(args.int("--hold-us", 0)), .seed = i * 7919 + @as(u64, @intCast(c.getpid())), .solo_order = args.int("--solo-order", 0) != 0 };
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

fn fileSize(path: []const u8) i64 {
    var buf: [max_path]u8 = undefined;
    const z = bufPrintZ(&buf, "{s}", .{path}) catch unreachable;
    var st: c.struct_stat = undefined;
    if (c.stat(z.ptr, &st) != 0) return 0;
    return st.st_size;
}

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
    const p = Paths.init(dir);
    var jbuf: [max_path]u8 = undefined;
    const journal = std.fmt.bufPrint(&jbuf, "{s}-cwal", .{p.list()[0]}) catch unreachable;
    out("bench mode={s} sync={s} kind={s} commits={d} mean_us={d:.1} p50_us={d:.1} p99_us={d:.1} syncs_per_commit={d:.2} journal_bytes={d}\n", .{
        @tagName(mode),                                                           sync,                                                   if (pair) "pair" else "solo",                                  commits,
        @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(commits)) / 1000.0, @as(f64, @floatFromInt(samples[commits / 2])) / 1000.0, @as(f64, @floatFromInt(samples[commits * 99 / 100])) / 1000.0, @as(f64, @floatFromInt(syncs)) / @as(f64, @floatFromInt(commits)),
        fileSize(journal),
    });
    conn.close();
}

const RwJob = struct {
    dir: []const u8,
    mode: cwal.Mode,
    deadline_ns: u64,
    count: u64 = 0,
    gate_wait_ns: u64 = 0,
    snapshot_reads: u64 = 0,
    seq_retries: u64 = 0,
    journal_skips: u64 = 0,
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
    job.gate_wait_ns = conn.stats.gate_wait_ns;
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
    job.gate_wait_ns = conn.stats.gate_wait_ns;
    job.snapshot_reads = conn.stats.snapshot_reads;
    job.seq_retries = conn.stats.seq_retries;
    job.journal_skips = conn.stats.journal_skips;
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
    var journal_skips: u64 = 0;
    for (0..readers) |i| {
        handles[i].join();
        reads += jobs[i].count;
        reader_wait += jobs[i].gate_wait_ns;
        snapshot_reads += jobs[i].snapshot_reads;
        seq_retries += jobs[i].seq_retries;
        journal_skips += jobs[i].journal_skips;
    }
    handles[16].join();
    const seconds = @as(f64, @floatFromInt(duration_ms)) / 1000.0;
    out("benchrw mode={s} readers={d} reads_per_s={d:.0} commits_per_s={d:.0} reader_gate_wait_ms={d:.1} writer_gate_wait_ms={d:.1} snapshot_reads={d} seq_retries={d} journal_skips={d}\n", .{
        @tagName(mode),                                  readers,                                    @as(f64, @floatFromInt(reads)) / seconds,
        @as(f64, @floatFromInt(writer.count)) / seconds, @as(f64, @floatFromInt(reader_wait)) / 1e6, @as(f64, @floatFromInt(writer.gate_wait_ns)) / 1e6,
        snapshot_reads,                                  seq_retries,                                journal_skips,
    });
}

// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init.Minimal) void {
    cwal.register();
    const list = init.args.toSlice(std.heap.c_allocator) catch die("args", .{});
    if (list.len < 3) die("usage: cwal <seed|writer|reader|check|recover|state|bench|benchrw> <dir> [options]", .{});
    const args: Args = .{ .list = list };
    const cmd = list[1];
    const dir = list[2];
    if (std.mem.eql(u8, cmd, "seed")) cmdSeed(dir) else if (std.mem.eql(u8, cmd, "writer")) cmdWriter(dir, args) else if (std.mem.eql(u8, cmd, "reader")) cmdReader(dir, args) else if (std.mem.eql(u8, cmd, "check")) cmdCheck(dir, args) else if (std.mem.eql(u8, cmd, "recover")) cmdRecover(dir, args) else if (std.mem.eql(u8, cmd, "state")) cmdState(dir) else if (std.mem.eql(u8, cmd, "bench")) cmdBench(dir, args) else if (std.mem.eql(u8, cmd, "benchrw")) cmdBenchRw(dir, args) else die("unknown command {s}", .{cmd});
}
