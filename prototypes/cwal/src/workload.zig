//! Realistic workloads over a five-file set laid out like Zova's stores:
//! relational rows in `main.db`, objects (`_zova_objects`, `_zova_chunks`,
//! `_zova_object_chunks`) in `s1.db`, vectors in `s2.db`, graph topology in
//! `s3.db` and binary key-value pairs in `s4.db`, with Zova's table and
//! index definitions. Compares plain WAL, rollback journal (SQLite's
//! super-journal makes multi-file commits atomic) and CWAL at the same
//! offered load.
//!
//! The writer is open-loop: op i is due at start + i / rate, and its
//! latency runs from that time, so a slow commit also delays (and is
//! charged to) the ops queued behind it. Readers are open-loop too.
const std = @import("std");
const c = @import("c");
const cwal = @import("cwal.zig");
const Conn = cwal.Conn;

pub const Mode = enum { plain, journal, cwal };
pub const Scenario = enum { mixed, objects, vectors, graph };

pub const Config = struct {
    mode: Mode = .cwal,
    scenario: Scenario = .mixed,
    /// Writer ops per second; 0 runs back to back (closed loop).
    rate: f64 = 0,
    readers: usize = 2,
    /// Read ops per second per reader; 0 runs back to back.
    read_rate: f64 = 0,
    duration_s: f64 = 10,
    report_s: f64 = 0,
    /// WAL modes: a PASSIVE checkpoint of every member after this many
    /// writer ops (inside that op, as SQLite's autocheckpoint would be).
    ckpt_every: u64 = 100,
    object_kib: u64 = 64,
    big_mib: u64 = 16,
    batch: u64 = 32,
    dims: usize = 384,
};

pub const SeedConfig = struct {
    journal: []const u8 = "wal",
    docs: u64 = 2000,
    object_kib: u64 = 16,
    big: u64 = 4,
    big_mib: u64 = 16,
    dims: usize = 384,
};

const files = [_][]const u8{ "main.db", "s1.db", "s2.db", "s3.db", "s4.db" };

const schemas = [_][:0]const u8{
    \\create table docs (id integer primary key, title text not null, body blob not null,
    \\  object_id blob, updated integer not null);
    \\create table bigs (id integer primary key, object_id blob not null, size_bytes integer not null);
    ,
    \\create table _zova_objects (
    \\  object_id blob not null primary key check (length(object_id) = 32),
    \\  size_bytes integer not null check (size_bytes >= 0),
    \\  chunk_count integer not null check (chunk_count >= 0),
    \\  chunker text not null check (chunker in ('fastcdc-v1', 'fixed-1m-v1')));
    \\create table _zova_chunks (
    \\  chunk_hash blob not null primary key check (length(chunk_hash) = 32),
    \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 1048576),
    \\  data blob not null check ((encoding = 0 and length(data) = size_bytes) or (encoding = 1 and length(data) < size_bytes)),
    \\  encoding integer not null default 0 check (encoding in (0, 1)));
    \\create table _zova_object_chunks (
    \\  object_id blob not null check (length(object_id) = 32),
    \\  chunk_index integer not null check (chunk_index >= 0),
    \\  chunk_hash blob not null check (length(chunk_hash) = 32),
    \\  offset integer not null check (offset >= 0),
    \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 1048576),
    \\  primary key (object_id, chunk_index),
    \\  foreign key (object_id) references _zova_objects(object_id),
    \\  foreign key (chunk_hash) references _zova_chunks(chunk_hash));
    \\create index _zova_object_chunks_chunk_hash_idx on _zova_object_chunks(chunk_hash);
    ,
    \\create table _zova_vector_collections (
    \\  collection_key integer primary key,
    \\  name text not null unique check (length(name) > 0 and length(name) <= 255),
    \\  dimensions integer not null check (dimensions > 0 and dimensions <= 16384),
    \\  metric text not null check (metric in ('cosine', 'l2', 'dot')),
    \\  element_type text not null check (element_type in ('f32', 'f16', 'i8')));
    \\create table _zova_vectors (
    \\  vector_key integer primary key,
    \\  collection_key integer not null,
    \\  vector_id text not null check (length(vector_id) > 0),
    \\  "values" blob not null check (length("values") > 0),
    \\  norm_squared real check (norm_squared is null or norm_squared >= 0),
    \\  unique (collection_key, vector_id),
    \\  foreign key (collection_key) references _zova_vector_collections(collection_key) on delete cascade);
    ,
    \\create table _zova_graphs (
    \\  graph_key integer primary key,
    \\  name text not null unique check (length(name) > 0 and length(name) <= 128),
    \\  created_order integer not null);
    \\create table _zova_graph_nodes (
    \\  node_key integer primary key,
    \\  graph_key integer not null,
    \\  node_id text not null check (length(node_id) > 0 and length(node_id) <= 512),
    \\  kind text not null check (length(kind) > 0 and length(kind) <= 128),
    \\  target_type text not null check (target_type in ('none', 'record', 'object', 'object_chunk', 'vector', 'entity', 'fact', 'concept', 'external')),
    \\  target_namespace text,
    \\  target_ref text,
    \\  created_order integer not null,
    \\  unique (graph_key, node_id),
    \\  unique (graph_key, node_key),
    \\  foreign key (graph_key) references _zova_graphs(graph_key) on delete cascade);
    \\create table _zova_graph_edge_types (
    \\  edge_type_key integer primary key,
    \\  graph_key integer not null,
    \\  name text not null check (length(name) > 0 and length(name) <= 128),
    \\  unique (graph_key, name),
    \\  unique (graph_key, edge_type_key),
    \\  foreign key (graph_key) references _zova_graphs(graph_key) on delete cascade);
    \\create table _zova_graph_edges (
    \\  edge_key integer primary key,
    \\  graph_key integer not null,
    \\  from_node_key integer not null,
    \\  edge_type_key integer not null,
    \\  to_node_key integer not null,
    \\  created_order integer not null,
    \\  payload blob not null default x'',
    \\  foreign key (graph_key) references _zova_graphs(graph_key) on delete cascade,
    \\  foreign key (graph_key, from_node_key) references _zova_graph_nodes(graph_key, node_key) on delete cascade,
    \\  foreign key (graph_key, to_node_key) references _zova_graph_nodes(graph_key, node_key) on delete cascade,
    \\  foreign key (graph_key, edge_type_key) references _zova_graph_edge_types(graph_key, edge_type_key) on delete cascade);
    \\create unique index _zova_graph_edges_topology_idx on _zova_graph_edges (from_node_key, edge_type_key, to_node_key);
    \\create index _zova_graph_nodes_created_order_idx on _zova_graph_nodes (graph_key, created_order, node_key);
    \\create index _zova_graph_edges_created_order_idx on _zova_graph_edges (graph_key, created_order, edge_key);
    \\create index _zova_graph_edges_from_node_idx on _zova_graph_edges (graph_key, from_node_key, created_order, to_node_key);
    \\create index _zova_graph_edges_from_node_type_idx on _zova_graph_edges (graph_key, from_node_key, edge_type_key, created_order, to_node_key);
    \\create index _zova_graph_edges_to_node_idx on _zova_graph_edges (graph_key, to_node_key, created_order, from_node_key);
    \\create index _zova_graph_edges_to_node_type_idx on _zova_graph_edges (graph_key, to_node_key, edge_type_key, created_order, from_node_key);
    ,
    \\create table _zova_kv (
    \\  namespace blob not null,
    \\  key blob not null,
    \\  value blob not null,
    \\  primary key (namespace, key)
    \\) without rowid;
};

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = c.write(1, text.ptr, text.len);
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    out("FAIL " ++ fmt ++ "\n", args);
    c.exit(1);
}

fn bufPrintZ(buf: []u8, comptime fmt: []const u8, args: anytype) [:0]u8 {
    return std.fmt.bufPrintSentinel(buf, fmt, args, 0) catch die("format", .{});
}

// ---------------------------------------------------------------------------
// Latency histogram: 32 sub-buckets per power of two (about 3% error),
// constant memory, so a 24-hour run keeps every sample.
// ---------------------------------------------------------------------------

const hist_buckets = 1920;

const Hist = struct {
    counts: [hist_buckets]u64 = @splat(0),
    n: u64 = 0,
    sum: u64 = 0,
    max: u64 = 0,

    fn index(v: u64) usize {
        if (v < 32) return @intCast(v);
        const e: u6 = @intCast(63 - @clz(v));
        const sub = (v >> (e - 5)) & 31;
        return (@as(usize, e) - 4) * 32 + @as(usize, @intCast(sub));
    }

    fn value(i: usize) u64 {
        if (i < 32) return i;
        const e: u6 = @intCast(i / 32 + 4);
        const lo = (32 + @as(u64, i % 32)) << (e - 5);
        return lo + (@as(u64, 1) << (e - 5)) / 2;
    }

    fn add(h: *Hist, v: u64) void {
        _ = @atomicRmw(u64, &h.counts[index(v)], .Add, 1, .monotonic);
        _ = @atomicRmw(u64, &h.n, .Add, 1, .monotonic);
        _ = @atomicRmw(u64, &h.sum, .Add, v, .monotonic);
        if (v > @atomicLoad(u64, &h.max, .monotonic)) @atomicStore(u64, &h.max, v, .monotonic);
    }

    fn snapshot(h: *const Hist) Hist {
        var s: Hist = .{};
        for (&s.counts, &h.counts) |*d, *src| d.* = @atomicLoad(u64, src, .monotonic);
        s.n = @atomicLoad(u64, &h.n, .monotonic);
        s.sum = @atomicLoad(u64, &h.sum, .monotonic);
        s.max = @atomicLoad(u64, &h.max, .monotonic);
        return s;
    }

    fn merge(h: *Hist, o: *const Hist) void {
        for (&h.counts, &o.counts) |*d, s| d.* += s;
        h.n += o.n;
        h.sum += o.sum;
        h.max = @max(h.max, o.max);
    }

    fn minus(h: Hist, o: *const Hist) Hist {
        var d = h;
        for (&d.counts, &o.counts) |*x, s| x.* -= s;
        d.n -= o.n;
        d.sum -= o.sum;
        return d;
    }

    fn pct(h: *const Hist, q: f64) u64 {
        if (h.n == 0) return 0;
        const target: u64 = @max(1, @as(u64, @intFromFloat(@ceil(q * @as(f64, @floatFromInt(h.n))))));
        var seen: u64 = 0;
        for (h.counts, 0..) |cnt, i| {
            seen += cnt;
            if (seen >= target) return @min(value(i), h.max);
        }
        return h.max;
    }
};

fn us(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

// ---------------------------------------------------------------------------
// Prepared statements on a Conn's database handle.
// ---------------------------------------------------------------------------

const Busy = error{Busy};

const Stmt = struct {
    s: *c.sqlite3_stmt,
    db: *c.sqlite3,

    fn prep(conn: *Conn, sql: [:0]const u8) Stmt {
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v3(conn.db, sql.ptr, -1, c.SQLITE_PREPARE_PERSISTENT, &s, null) != c.SQLITE_OK)
            die("prepare {s}: {s}", .{ sql, c.sqlite3_errmsg(conn.db) });
        return .{ .s = s.?, .db = conn.db.? };
    }

    fn blob(st: Stmt, i: c_int, data: []const u8) void {
        _ = c.sqlite3_bind_blob(st.s, i, data.ptr, @intCast(data.len), null);
    }
    fn text(st: Stmt, i: c_int, data: []const u8) void {
        _ = c.sqlite3_bind_text(st.s, i, data.ptr, @intCast(data.len), null);
    }
    fn int(st: Stmt, i: c_int, v: i64) void {
        _ = c.sqlite3_bind_int64(st.s, i, v);
    }
    fn real(st: Stmt, i: c_int, v: f64) void {
        _ = c.sqlite3_bind_double(st.s, i, v);
    }

    /// Next row (true) or done (false, statement reset).
    fn step(st: Stmt) Busy!bool {
        const rc = c.sqlite3_step(st.s);
        if (rc == c.SQLITE_ROW) return true;
        _ = c.sqlite3_reset(st.s);
        if (rc == c.SQLITE_DONE) return false;
        if (rc & 0xff == c.SQLITE_BUSY or rc & 0xff == c.SQLITE_LOCKED) return error.Busy;
        die("step {s}: {s}", .{ c.sqlite3_sql(st.s), c.sqlite3_errmsg(st.db) });
    }

    fn run(st: Stmt) Busy!void {
        while (try st.step()) {}
    }

    fn reset(st: Stmt) void {
        _ = c.sqlite3_reset(st.s);
    }

    fn colInt(st: Stmt, i: c_int) i64 {
        return c.sqlite3_column_int64(st.s, i);
    }
    fn colBlob(st: Stmt, i: c_int) []const u8 {
        const p: ?[*]const u8 = @ptrCast(c.sqlite3_column_blob(st.s, i));
        const n: usize = @intCast(c.sqlite3_column_bytes(st.s, i));
        return if (p) |q| q[0..n] else &.{};
    }

    /// First column of the first row as an integer (0 if none).
    fn scalar(st: Stmt) Busy!i64 {
        const v = if (try st.step()) st.colInt(0) else 0;
        st.reset();
        return v;
    }

    fn finalize(st: Stmt) void {
        _ = c.sqlite3_finalize(st.s);
    }
};

fn isBusy(conn: *Conn) bool {
    const rc = c.sqlite3_errcode(conn.db) & 0xff;
    return rc == c.SQLITE_BUSY or rc == c.SQLITE_LOCKED;
}

// ---------------------------------------------------------------------------
// Data: a pool of random bytes, sliced at random offsets with a unique
// prefix, so generating data costs nothing measurable.
// ---------------------------------------------------------------------------

const pool_size = 64 << 20;
var pool: []u8 = &.{};
var unique = std.atomic.Value(u64).init(1);

fn initPool() void {
    if (pool.len != 0) return;
    pool = std.heap.c_allocator.alloc(u8, pool_size) catch die("oom", .{});
    var rng = std.Random.DefaultPrng.init(0x5eed);
    rng.random().bytes(pool);
}

/// `len` bytes of distinct content, in buf.
fn content(buf: []u8, len: usize, rand: std.Random) []u8 {
    const off = rand.uintLessThan(usize, pool_size - len);
    @memcpy(buf[0..len], pool[off..][0..len]);
    if (len >= 8) std.mem.writeInt(u64, buf[0..8], unique.fetchAdd(1, .monotonic), .little);
    return buf[0..len];
}

// ---------------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------------

const WriterOps = enum { ingest, update, link, kvput, bigobj, vbatch, gupdate, checkpoint };
const ReaderOps = enum { doc_read, vsearch, traverse, obj_stream };

const Writer = struct {
    conn: *Conn,
    cfg: Config,
    rand: std.Random,
    next_doc: i64,
    next_node: i64,
    next_big: i64,
    payload: u64 = 0,
    buf: []u8,
    vec: []f32,
    ins_doc: Stmt,
    upd_doc: Stmt,
    touch_doc: Stmt,
    ins_big: Stmt,
    ins_obj: Stmt,
    ins_chunk: Stmt,
    ins_ochunk: Stmt,
    ins_vec: Stmt,
    ins_node: Stmt,
    ins_edge: Stmt,
    kv_put: Stmt,

    fn init(conn: *Conn, cfg: Config, rand: std.Random) Writer {
        initPool();
        const max_doc = Stmt.prep(conn, "select coalesce(max(id), 0) from main.docs");
        const max_node = Stmt.prep(conn, "select coalesce(max(node_key), 0) from m3._zova_graph_nodes");
        const max_big = Stmt.prep(conn, "select coalesce(max(id), 0) from main.bigs");
        defer max_doc.finalize();
        defer max_node.finalize();
        defer max_big.finalize();
        return .{
            .conn = conn,
            .cfg = cfg,
            .rand = rand,
            .next_doc = (max_doc.scalar() catch die("busy", .{})) + 1,
            .next_node = (max_node.scalar() catch die("busy", .{})) + 1,
            .next_big = (max_big.scalar() catch die("busy", .{})) + 1,
            .buf = std.heap.c_allocator.alloc(u8, 1 << 20) catch die("oom", .{}),
            .vec = std.heap.c_allocator.alloc(f32, cfg.dims) catch die("oom", .{}),
            .ins_doc = Stmt.prep(conn, "insert into main.docs (id, title, body, object_id, updated) values (?1, ?2, ?3, ?4, ?5)"),
            .upd_doc = Stmt.prep(conn, "update main.docs set body = ?2, updated = ?3 where id = ?1"),
            .touch_doc = Stmt.prep(conn, "update main.docs set updated = ?2 where id = ?1"),
            .ins_big = Stmt.prep(conn, "insert into main.bigs (id, object_id, size_bytes) values (?1, ?2, ?3)"),
            .ins_obj = Stmt.prep(conn, "insert or ignore into m1._zova_objects values (?1, ?2, ?3, ?4)"),
            .ins_chunk = Stmt.prep(conn, "insert or ignore into m1._zova_chunks (chunk_hash, size_bytes, data, encoding) values (?1, ?2, ?3, 0)"),
            .ins_ochunk = Stmt.prep(conn, "insert into m1._zova_object_chunks values (?1, ?2, ?3, ?4, ?5)"),
            .ins_vec = Stmt.prep(conn, "insert into m2._zova_vectors (collection_key, vector_id, \"values\", norm_squared) values (1, ?1, ?2, 1.0)"),
            .ins_node = Stmt.prep(conn, "insert into m3._zova_graph_nodes (node_key, graph_key, node_id, kind, target_type, target_namespace, target_ref, created_order) values (?1, 1, ?2, 'doc', 'record', 'docs', ?3, ?1)"),
            .ins_edge = Stmt.prep(conn, "insert or ignore into m3._zova_graph_edges (graph_key, from_node_key, edge_type_key, to_node_key, created_order) values (1, ?1, 1, ?2, ?3)"),
            .kv_put = Stmt.prep(conn, "insert or replace into m4._zova_kv values (?1, ?2, ?3)"),
        };
    }

    fn deinit(w: *Writer) void {
        inline for (.{ "ins_doc", "upd_doc", "touch_doc", "ins_big", "ins_obj", "ins_chunk", "ins_ochunk", "ins_vec", "ins_node", "ins_edge", "kv_put" }) |f| @field(w, f).finalize();
    }

    fn randomDoc(w: *Writer) i64 {
        return 1 + @as(i64, @intCast(w.rand.uintLessThan(u64, @intCast(@max(1, w.next_doc - 1)))));
    }
    fn randomNode(w: *Writer) i64 {
        return 1 + @as(i64, @intCast(w.rand.uintLessThan(u64, @intCast(@max(1, w.next_node - 1)))));
    }

    /// Stores size bytes as an object in chunks of chunk bytes (each
    /// hashed, as Zova does), returns the object id.
    fn object(w: *Writer, size: usize, chunk: usize, chunker: []const u8) Busy![32]u8 {
        var whole = std.crypto.hash.sha2.Sha256.init(.{});
        var hashes: [4096][32]u8 = undefined;
        const n = (size + chunk - 1) / chunk;
        for (0..n) |i| {
            const len = @min(chunk, size - i * chunk);
            const data = content(w.buf, len, w.rand);
            whole.update(data);
            std.crypto.hash.sha2.Sha256.hash(data, &hashes[i], .{});
            w.ins_chunk.blob(1, &hashes[i]);
            w.ins_chunk.int(2, @intCast(len));
            w.ins_chunk.blob(3, data);
            try w.ins_chunk.run();
            w.payload += len;
        }
        const id = whole.finalResult();
        w.ins_obj.blob(1, &id);
        w.ins_obj.int(2, @intCast(size));
        w.ins_obj.int(3, @intCast(n));
        w.ins_obj.text(4, chunker);
        try w.ins_obj.run();
        for (0..n) |i| {
            w.ins_ochunk.blob(1, &id);
            w.ins_ochunk.int(2, @intCast(i));
            w.ins_ochunk.blob(3, &hashes[i]);
            w.ins_ochunk.int(4, @intCast(i * chunk));
            w.ins_ochunk.int(5, @intCast(@min(chunk, size - i * chunk)));
            try w.ins_ochunk.run();
        }
        return id;
    }

    fn vector(w: *Writer, id: []const u8) Busy!void {
        var norm: f32 = 0;
        for (w.vec) |*x| {
            x.* = w.rand.float(f32) - 0.5;
            norm += x.* * x.*;
        }
        const inv = 1.0 / @sqrt(norm);
        for (w.vec) |*x| x.* *= inv;
        w.ins_vec.text(1, id);
        w.ins_vec.blob(2, std.mem.sliceAsBytes(w.vec));
        try w.ins_vec.run();
        w.payload += w.vec.len * 4 + id.len;
    }

    fn kv(w: *Writer, ns: []const u8, key: i64, vlen: usize) Busy!void {
        var k: [8]u8 = undefined;
        std.mem.writeInt(i64, &k, key, .big);
        var v: [256]u8 = undefined;
        w.kv_put.blob(1, ns);
        w.kv_put.blob(2, &k);
        w.kv_put.blob(3, content(&v, vlen, w.rand));
        try w.kv_put.run();
        w.payload += ns.len + 8 + vlen;
    }

    fn doc(w: *Writer, id: i64, body_len: usize, object_id: ?[]const u8) Busy!void {
        var title: [32]u8 = undefined;
        const t = std.fmt.bufPrint(&title, "doc {d}", .{id}) catch unreachable;
        var body: [4096]u8 = undefined;
        w.ins_doc.int(1, id);
        w.ins_doc.text(2, t);
        w.ins_doc.blob(3, content(&body, body_len, w.rand));
        if (object_id) |o| w.ins_doc.blob(4, o) else _ = c.sqlite3_bind_null(w.ins_doc.s, 4);
        w.ins_doc.int(5, @intCast(cwal.monotonicNs()));
        try w.ins_doc.run();
        w.payload += t.len + body_len + 8;
    }

    fn node(w: *Writer, key: i64, edges: usize) Busy!void {
        var id: [32]u8 = undefined;
        const nid = std.fmt.bufPrint(&id, "n{d}", .{key}) catch unreachable;
        w.ins_node.int(1, key);
        w.ins_node.text(2, nid);
        w.ins_node.text(3, nid);
        try w.ins_node.run();
        w.payload += 2 * nid.len + 16;
        for (0..edges) |_| try w.edge(key, w.randomNode());
    }

    fn edge(w: *Writer, from: i64, to: i64) Busy!void {
        w.ins_edge.int(1, from);
        w.ins_edge.int(2, to);
        w.ins_edge.int(3, @intCast(cwal.monotonicNs()));
        try w.ins_edge.run();
        w.payload += 24;
    }

    /// One document: relational row, object, vector, graph node with three
    /// edges, metadata pair. Writes all five files.
    fn ingest(w: *Writer, object_kib: u64) Busy!void {
        const id = w.next_doc;
        const o = try w.object(object_kib * 1024, 64 * 1024, "fastcdc-v1");
        try w.doc(id, 1024, &o);
        var vid: [32]u8 = undefined;
        try w.vector(std.fmt.bufPrint(&vid, "doc-{d}", .{id}) catch unreachable);
        try w.node(w.next_node, 3);
        try w.kv("doc", id, 64);
        w.next_doc += 1;
        w.next_node += 1;
    }

    fn op(w: *Writer, kind: WriterOps) Busy!void {
        switch (kind) {
            .ingest => try w.ingest(w.cfg.object_kib),
            .update => {
                const id = w.randomDoc();
                var body: [1024]u8 = undefined;
                w.upd_doc.int(1, id);
                w.upd_doc.blob(2, content(&body, body.len, w.rand));
                w.upd_doc.int(3, @intCast(cwal.monotonicNs()));
                try w.upd_doc.run();
                w.payload += body.len + 8;
                try w.kv("doc", id, 64);
            },
            .link => {
                try w.edge(w.randomNode(), w.randomNode());
                try w.edge(w.randomNode(), w.randomNode());
                try w.touch(w.randomDoc());
            },
            .kvput => try w.kv("counter", @intCast(w.rand.uintLessThan(u64, 10_000)), 32),
            .bigobj => {
                const size = w.cfg.big_mib << 20;
                const o = try w.object(size, 1 << 20, "fixed-1m-v1");
                w.ins_big.int(1, w.next_big);
                w.ins_big.blob(2, &o);
                w.ins_big.int(3, @intCast(size));
                try w.ins_big.run();
                try w.kv("big", w.next_big, 64);
                w.next_big += 1;
            },
            .vbatch => {
                for (0..w.cfg.batch) |_| {
                    try w.doc(w.next_doc, 128, null);
                    var vid: [32]u8 = undefined;
                    try w.vector(std.fmt.bufPrint(&vid, "doc-{d}", .{w.next_doc}) catch unreachable);
                    w.next_doc += 1;
                }
            },
            .gupdate => {
                try w.node(w.next_node, 4);
                w.next_node += 1;
                try w.kv("node", w.next_node - 1, 32);
                try w.touch(w.randomDoc());
            },
            .checkpoint => unreachable,
        }
    }

    fn touch(w: *Writer, id: i64) Busy!void {
        w.touch_doc.int(1, id);
        w.touch_doc.int(2, @intCast(cwal.monotonicNs()));
        try w.touch_doc.run();
        w.payload += 8;
    }

    fn pick(w: *Writer) WriterOps {
        return switch (w.cfg.scenario) {
            .mixed => blk: {
                const r = w.rand.uintLessThan(u32, 100);
                break :blk if (r < 40) .ingest else if (r < 70) .update else if (r < 90) .link else .kvput;
            },
            .objects => .bigobj,
            .vectors => .vbatch,
            .graph => .gupdate,
        };
    }

    /// One transaction; retried on SQLITE_BUSY. Returns the retries.
    fn transaction(w: *Writer, kind: WriterOps) u64 {
        var retries: u64 = 0;
        while (true) : (retries += 1) {
            const saved = .{ w.next_doc, w.next_node, w.next_big, w.payload };
            w.conn.exec("begin") catch die("begin", .{});
            const ok = if (w.op(kind)) |_| true else |_| false;
            if (ok) {
                if (w.conn.commit()) |_| return retries else |_| if (!isBusy(w.conn)) die("commit: {s}", .{c.sqlite3_errmsg(w.conn.db)});
            }
            w.conn.rollbackOpen();
            w.next_doc, w.next_node, w.next_big, w.payload = saved;
            _ = c.usleep(1000);
        }
    }
};

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

const Reader = struct {
    conn: *Conn,
    cfg: Config,
    rand: std.Random,
    bytes: u64 = 0,
    query: []f32,
    row: []f32,
    max_doc: Stmt,
    max_node: Stmt,
    max_big: Stmt,
    get_doc: Stmt,
    get_chunks: Stmt,
    get_kv: Stmt,
    get_vec: Stmt,
    all_vecs: Stmt,
    out_edges: Stmt,
    get_node: Stmt,
    get_big: Stmt,

    fn init(conn: *Conn, cfg: Config, rand: std.Random) Reader {
        return .{
            .conn = conn,
            .cfg = cfg,
            .rand = rand,
            .query = std.heap.c_allocator.alloc(f32, cfg.dims) catch die("oom", .{}),
            .row = std.heap.c_allocator.alloc(f32, cfg.dims) catch die("oom", .{}),
            .max_doc = Stmt.prep(conn, "select coalesce(max(id), 0) from main.docs"),
            .max_node = Stmt.prep(conn, "select coalesce(max(node_key), 0) from m3._zova_graph_nodes"),
            .max_big = Stmt.prep(conn, "select coalesce(max(id), 0) from main.bigs"),
            .get_doc = Stmt.prep(conn, "select title, body, object_id from main.docs where id = ?1"),
            .get_chunks = Stmt.prep(conn, "select c.data from m1._zova_object_chunks oc join m1._zova_chunks c on c.chunk_hash = oc.chunk_hash where oc.object_id = ?1 order by oc.chunk_index"),
            .get_kv = Stmt.prep(conn, "select value from m4._zova_kv where namespace = ?1 and key = ?2"),
            .get_vec = Stmt.prep(conn, "select \"values\" from m2._zova_vectors where collection_key = 1 and vector_id = ?1"),
            .all_vecs = Stmt.prep(conn, "select vector_key, \"values\" from m2._zova_vectors where collection_key = 1"),
            .out_edges = Stmt.prep(conn, "select to_node_key from m3._zova_graph_edges where graph_key = 1 and from_node_key = ?1"),
            .get_node = Stmt.prep(conn, "select node_id, target_ref from m3._zova_graph_nodes where node_key = ?1"),
            .get_big = Stmt.prep(conn, "select object_id from main.bigs where id = ?1"),
        };
    }

    fn deinit(r: *Reader) void {
        inline for (.{ "max_doc", "max_node", "max_big", "get_doc", "get_chunks", "get_kv", "get_vec", "all_vecs", "out_edges", "get_node", "get_big" }) |f| @field(r, f).finalize();
    }

    fn pick(r: *Reader) ReaderOps {
        return switch (r.cfg.scenario) {
            .mixed => blk: {
                const x = r.rand.uintLessThan(u32, 100);
                break :blk if (x < 50) .doc_read else if (x < 60) .vsearch else .traverse;
            },
            .objects => .obj_stream,
            .vectors => .vsearch,
            .graph => .traverse,
        };
    }

    fn below(r: *Reader, max: i64) i64 {
        return 1 + @as(i64, @intCast(r.rand.uintLessThan(u64, @intCast(@max(1, max)))));
    }

    fn streamObject(r: *Reader, id: []const u8) Busy!void {
        r.get_chunks.blob(1, id);
        while (try r.get_chunks.step()) {
            const d = r.get_chunks.colBlob(0);
            r.bytes += d.len;
            if (d.len != 0) std.mem.doNotOptimizeAway(d[d.len - 1]);
        }
    }

    fn op(r: *Reader, kind: ReaderOps) Busy!void {
        switch (kind) {
            // A document and everything that belongs to it: five files in
            // one snapshot.
            .doc_read => {
                const id = r.below(try r.max_doc.scalar());
                r.get_doc.int(1, id);
                var object_id: [32]u8 = undefined;
                var has_object = false;
                if (try r.get_doc.step()) {
                    const o = r.get_doc.colBlob(2);
                    if (o.len == 32) {
                        @memcpy(&object_id, o);
                        has_object = true;
                    }
                    r.bytes += r.get_doc.colBlob(1).len;
                    r.get_doc.reset();
                }
                if (has_object) try r.streamObject(&object_id);
                var k: [8]u8 = undefined;
                std.mem.writeInt(i64, &k, id, .big);
                r.get_kv.blob(1, "doc");
                r.get_kv.blob(2, &k);
                try r.get_kv.run();
                var vid: [32]u8 = undefined;
                r.get_vec.text(1, std.fmt.bufPrint(&vid, "doc-{d}", .{id}) catch unreachable);
                try r.get_vec.run();
                r.get_node.int(1, id);
                try r.get_node.run();
            },
            // Exact top-10 by dot product (vectors are unit length).
            .vsearch => {
                for (r.query) |*x| x.* = r.rand.float(f32) - 0.5;
                var top: [10]f32 = @splat(-std.math.inf(f32));
                while (try r.all_vecs.step()) {
                    const b = r.all_vecs.colBlob(1);
                    if (b.len != r.row.len * 4) continue;
                    @memcpy(std.mem.sliceAsBytes(r.row), b);
                    var acc: @Vector(8, f32) = @splat(0);
                    var i: usize = 0;
                    while (i + 8 <= r.row.len) : (i += 8) acc += @as(@Vector(8, f32), r.row[i..][0..8].*) * @as(@Vector(8, f32), r.query[i..][0..8].*);
                    var s = @reduce(.Add, acc);
                    while (i < r.row.len) : (i += 1) s += r.row[i] * r.query[i];
                    if (s > top[9]) {
                        var j: usize = 9;
                        while (j > 0 and top[j - 1] < s) : (j -= 1) top[j] = top[j - 1];
                        top[j] = s;
                    }
                    r.bytes += b.len;
                }
                std.mem.doNotOptimizeAway(top[0]);
            },
            // Two hops out from a random node, resolving the first hop.
            .traverse => {
                const start = r.below(try r.max_node.scalar());
                var hop1: [256]i64 = undefined;
                var n1: usize = 0;
                r.out_edges.int(1, start);
                while (try r.out_edges.step()) {
                    if (n1 < hop1.len) {
                        hop1[n1] = r.out_edges.colInt(0);
                        n1 += 1;
                    }
                }
                var reached: u64 = 0;
                for (hop1[0..n1]) |n| {
                    r.get_node.int(1, n);
                    try r.get_node.run();
                    r.out_edges.int(1, n);
                    while (try r.out_edges.step()) reached += 1;
                }
                std.mem.doNotOptimizeAway(reached);
            },
            .obj_stream => {
                const max = try r.max_big.scalar();
                if (max == 0) return;
                r.get_big.int(1, r.below(max));
                var object_id: [32]u8 = undefined;
                if (try r.get_big.step()) {
                    @memcpy(&object_id, r.get_big.colBlob(0)[0..32]);
                    r.get_big.reset();
                    try r.streamObject(&object_id);
                }
            },
        }
    }

    /// Starts a read transaction on every member. CWAL opens a cross-file
    /// snapshot; the other modes read each member in order, as
    /// Conn.beginRead does, but keep SQLITE_BUSY visible for a retry.
    fn begin(r: *Reader) Busy!void {
        if (r.cfg.mode == .cwal) {
            r.conn.beginRead(0) catch {
                if (isBusy(r.conn)) return error.Busy;
                die("beginRead: {s}", .{c.sqlite3_errmsg(r.conn.db)});
            };
            return;
        }
        if (c.sqlite3_exec(r.conn.db, "begin", null, null, null) != c.SQLITE_OK) die("begin", .{});
        for (0..files.len) |i| {
            var buf: [64]u8 = undefined;
            const sql = bufPrintZ(&buf, "select count(*) from {s}.sqlite_schema", .{Conn.schemaName(i)});
            if (c.sqlite3_exec(r.conn.db, sql.ptr, null, null, null) != c.SQLITE_OK) {
                const busy = isBusy(r.conn);
                _ = c.sqlite3_exec(r.conn.db, "rollback", null, null, null);
                if (busy) return error.Busy;
                die("{s}: {s}", .{ sql, c.sqlite3_errmsg(r.conn.db) });
            }
        }
    }

    /// One read transaction (a cross-file snapshot); retried on busy.
    fn transaction(r: *Reader, kind: ReaderOps) u64 {
        var retries: u64 = 0;
        while (true) : (retries += 1) {
            if (r.begin()) |_| {
                const ok = if (r.op(kind)) |_| true else |_| false;
                _ = c.sqlite3_exec(r.conn.db, "rollback", null, null, null);
                if (ok) return retries;
            } else |_| {}
            _ = c.usleep(1000);
        }
    }
};

// ---------------------------------------------------------------------------
// Seeding
// ---------------------------------------------------------------------------

fn paths(dir: []const u8, bufs: *[files.len][1024]u8) [files.len][]const u8 {
    var l: [files.len][]const u8 = undefined;
    for (files, 0..) |f, i| l[i] = std.fmt.bufPrint(&bufs[i], "{s}/{s}", .{ dir, f }) catch die("path", .{});
    return l;
}

pub fn seed(dir: []const u8, cfg: SeedConfig) void {
    var bufs: [files.len][1024]u8 = undefined;
    const l = paths(dir, &bufs);
    for (l, schemas) |p, schema| {
        var zb: [1100]u8 = undefined;
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open(bufPrintZ(&zb, "{s}", .{p}).ptr, &db) != c.SQLITE_OK) die("open {s}", .{p});
        var sql: [64]u8 = undefined;
        var msg: [*c]u8 = null;
        if (c.sqlite3_exec(db, bufPrintZ(&sql, "pragma journal_mode={s}", .{cfg.journal}).ptr, null, null, &msg) != c.SQLITE_OK or
            c.sqlite3_exec(db, schema.ptr, null, null, &msg) != c.SQLITE_OK) die("seed {s}: {s}", .{ p, msg });
        _ = c.sqlite3_close(db);
    }
    const conn = Conn.open(&l, .{ .mode = .plain, .role = .writer }) catch die("open set", .{});
    conn.exec("insert into m2._zova_vector_collections values (1, 'docs', " ++ "384" ++ ", 'cosine', 'f32')") catch die("collection", .{});
    conn.exec("insert into m3._zova_graphs values (1, 'g', 0)") catch die("graph", .{});
    conn.exec("insert into m3._zova_graph_edge_types values (1, 1, 'links')") catch die("edge type", .{});
    var prng = std.Random.DefaultPrng.init(42);
    var w = Writer.init(conn, .{ .dims = cfg.dims, .big_mib = cfg.big_mib, .object_kib = cfg.object_kib }, prng.random());
    // The first node has no earlier node to link to: edges from it point
    // to itself.
    conn.exec("begin") catch die("begin", .{});
    for (0..cfg.docs) |i| {
        w.ingest(cfg.object_kib) catch die("busy", .{});
        if (i % 500 == 499) {
            conn.exec("commit") catch die("commit", .{});
            conn.exec("begin") catch die("begin", .{});
        }
    }
    for (0..cfg.big) |_| w.op(.bigobj) catch die("busy", .{});
    conn.exec("commit") catch die("commit", .{});
    w.deinit();
    conn.close();
    var total: u64 = 0;
    for (l) |p| {
        var zb: [1100]u8 = undefined;
        var st: c.struct_stat = undefined;
        if (c.stat(bufPrintZ(&zb, "{s}", .{p}).ptr, &st) == 0) total += @intCast(st.st_size);
    }
    out("wseed journal={s} docs={d} object_kib={d} big={d} big_mib={d} payload_mb={d:.1} files_mb={d:.1}\n", .{ cfg.journal, cfg.docs, cfg.object_kib, cfg.big, cfg.big_mib, @as(f64, @floatFromInt(w.payload)) / 1048576.0, @as(f64, @floatFromInt(total)) / 1048576.0 });
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

/// Sleep until monotonic time `ns` (absolute).
fn sleepUntil(ns: u64) void {
    var ts: [2]c_long = .{ @intCast(ns / 1_000_000_000), @intCast(ns % 1_000_000_000) };
    while (c.clock_nanosleep(c.CLOCK_MONOTONIC, 1, @ptrCast(&ts), null) != 0) {}
}

fn threadCpuNs() u64 {
    var ru: c.struct_rusage = undefined;
    _ = c.getrusage(1, &ru); // RUSAGE_THREAD
    return @as(u64, @intCast(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec)) * 1000;
}

const Shared = struct {
    cfg: Config,
    dir: []const u8,
    start_ns: u64 = 0,
    end_ns: u64 = 0,
    stop: std.atomic.Value(bool) = .init(false),
};

const WriterJob = struct {
    shared: *Shared,
    hists: [@typeInfo(WriterOps).@"enum".field_names.len]Hist = @splat(.{}),
    all: Hist = .{},
    ops: std.atomic.Value(u64) = .init(0),
    retries: u64 = 0,
    payload: std.atomic.Value(u64) = .init(0),
    ckpt_ns: u64 = 0,
    ckpt_runs: u64 = 0,
    /// Checkpoint runs that backfilled every frame of every member.
    ckpt_complete: std.atomic.Value(u64) = .init(0),
    cpu_ns: u64 = 0,
    max_lag_ns: u64 = 0,
    conn: ?*Conn = null,
};

const ReaderJob = struct {
    shared: *Shared,
    seed: u64,
    hists: [@typeInfo(ReaderOps).@"enum".field_names.len]Hist = @splat(.{}),
    all: Hist = .{},
    ops: std.atomic.Value(u64) = .init(0),
    retries: u64 = 0,
    bytes: u64 = 0,
    cpu_ns: u64 = 0,
    snapshot_reads: u64 = 0,
    window_wait_ns: u64 = 0,
};

fn connMode(m: Mode) cwal.Mode {
    return if (m == .cwal) .cwal else .plain;
}

fn openSet(shared: *Shared, role: cwal.Role) *Conn {
    var bufs: [files.len][1024]u8 = undefined;
    const l = paths(shared.dir, &bufs);
    return Conn.open(&l, .{ .mode = connMode(shared.cfg.mode), .role = role }) catch |e| die("open {s}: {s}", .{ @tagName(role), @errorName(e) });
}

fn writerThread(job: *WriterJob) void {
    const cfg = job.shared.cfg;
    const conn = job.conn.?;
    var prng = std.Random.DefaultPrng.init(7);
    var w = Writer.init(conn, cfg, prng.random());
    const period: u64 = if (cfg.rate > 0) @intFromFloat(1e9 / cfg.rate) else 0;
    var i: u64 = 0;
    while (!job.shared.stop.load(.monotonic)) : (i += 1) {
        const due = job.shared.start_ns + i * period;
        if (period != 0) {
            if (due >= job.shared.end_ns) break;
            sleepUntil(due);
        }
        const begin = if (period != 0) due else cwal.monotonicNs();
        const kind = w.pick();
        job.retries += w.transaction(kind);
        if (cfg.mode != .journal and cfg.ckpt_every != 0 and (i + 1) % cfg.ckpt_every == 0) {
            const t = cwal.monotonicNs();
            var complete = true;
            for (0..files.len) |m| {
                var log: c_int = 0;
                var done: c_int = 0;
                const rc = c.sqlite3_wal_checkpoint_v2(conn.db, Conn.schemaName(m).ptr, c.SQLITE_CHECKPOINT_PASSIVE, &log, &done);
                if (rc != c.SQLITE_OK or done < log) complete = false;
            }
            job.ckpt_ns += cwal.monotonicNs() - t;
            job.ckpt_runs += 1;
            if (complete) _ = job.ckpt_complete.fetchAdd(1, .monotonic);
        }
        const end = cwal.monotonicNs();
        job.hists[@backingInt(kind)].add(end - begin);
        job.all.add(end - begin);
        if (period != 0) job.max_lag_ns = @max(job.max_lag_ns, end - due);
        job.payload.store(w.payload, .monotonic);
        _ = job.ops.fetchAdd(1, .monotonic);
        if (period == 0 and end >= job.shared.end_ns) break;
    }
    job.cpu_ns = threadCpuNs();
    w.deinit();
}

fn readerThread(job: *ReaderJob) void {
    const cfg = job.shared.cfg;
    const conn = openSet(job.shared, .reader);
    // Rollback-journal readers lock members one at a time. A reader that
    // holds main.db while the writer, spilling a large transaction, holds
    // s1.db exclusively would wait on each other until the busy timeout:
    // readers give up quickly and retry instead.
    if (cfg.mode == .journal) _ = c.sqlite3_busy_timeout(conn.db, 5);
    var prng = std.Random.DefaultPrng.init(job.seed);
    var r = Reader.init(conn, cfg, prng.random());
    const period: u64 = if (cfg.read_rate > 0) @intFromFloat(1e9 / cfg.read_rate) else 0;
    // Stagger the readers' schedules.
    const offset = if (period != 0) prng.random().uintLessThan(u64, period) else 0;
    var i: u64 = 0;
    while (!job.shared.stop.load(.monotonic)) : (i += 1) {
        const due = job.shared.start_ns + offset + i * period;
        if (period != 0) {
            if (due >= job.shared.end_ns) break;
            sleepUntil(due);
        }
        const begin = if (period != 0) due else cwal.monotonicNs();
        const kind = r.pick();
        job.retries += r.transaction(kind);
        const end = cwal.monotonicNs();
        job.hists[@backingInt(kind)].add(end - begin);
        job.all.add(end - begin);
        _ = job.ops.fetchAdd(1, .monotonic);
        if (period == 0 and end >= job.shared.end_ns) break;
    }
    job.bytes = r.bytes;
    job.cpu_ns = threadCpuNs();
    job.snapshot_reads = conn.stats.snapshot_reads;
    job.window_wait_ns = conn.stats.window_wait_ns;
    r.deinit();
    conn.close();
}

const ProcIo = struct { wchar: u64 = 0, write_bytes: u64 = 0 };

fn procIo() ProcIo {
    var buf: [1024]u8 = undefined;
    const fd = c.open("/proc/self/io", c.O_RDONLY);
    if (fd < 0) return .{};
    defer _ = c.close(fd);
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return .{};
    var r: ProcIo = .{};
    var it = std.mem.tokenizeScalar(u8, buf[0..@intCast(n)], '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "wchar: ")) r.wchar = std.fmt.parseInt(u64, line[7..], 10) catch 0;
        if (std.mem.startsWith(u8, line, "write_bytes: ")) r.write_bytes = std.fmt.parseInt(u64, line[13..], 10) catch 0;
    }
    return r;
}

fn rssBytes() u64 {
    var buf: [128]u8 = undefined;
    const fd = c.open("/proc/self/statm", c.O_RDONLY);
    if (fd < 0) return 0;
    defer _ = c.close(fd);
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return 0;
    var it = std.mem.tokenizeScalar(u8, buf[0..@intCast(n)], ' ');
    _ = it.next();
    const pages = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
    return pages * 4096;
}

fn fileSize(dir: []const u8, name: []const u8, suffix: []const u8) u64 {
    var zb: [1100]u8 = undefined;
    var st: c.struct_stat = undefined;
    if (c.stat(bufPrintZ(&zb, "{s}/{s}{s}", .{ dir, name, suffix }).ptr, &st) != 0) return 0;
    return @intCast(st.st_size);
}

fn walBytes(dir: []const u8) u64 {
    var t: u64 = 0;
    for (files) |f| t += fileSize(dir, f, "-wal");
    return t;
}

fn dbBytes(dir: []const u8) u64 {
    var t: u64 = 0;
    for (files) |f| t += fileSize(dir, f, "");
    return t;
}

fn mb(b: u64) f64 {
    return @as(f64, @floatFromInt(b)) / 1048576.0;
}

pub fn run(dir: []const u8, cfg: Config) void {
    var shared: Shared = .{ .cfg = cfg, .dir = dir };
    // The writer opens first, so it runs any recovery.
    var wjob: WriterJob = .{ .shared = &shared, .conn = openSet(&shared, .writer) };
    {
        var jm: [16]u8 = undefined;
        var st: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(wjob.conn.?.db, "pragma main.journal_mode", -1, &st, null);
        const got = if (c.sqlite3_step(st) == c.SQLITE_ROW) std.mem.span(c.sqlite3_column_text(st, 0)) else "";
        const n = @min(got.len, jm.len);
        @memcpy(jm[0..n], got[0..n]);
        _ = c.sqlite3_finalize(st);
        const want: []const u8 = if (cfg.mode == .journal) "delete" else "wal";
        if (!std.ascii.eqlIgnoreCase(jm[0..n], want)) die("set is in journal mode {s}; --mode {s} needs {s} (wseed --journal)", .{ jm[0..n], @tagName(cfg.mode), want });
    }
    initPool();
    const rjobs = std.heap.c_allocator.alloc(ReaderJob, cfg.readers) catch die("oom", .{});
    var threads: [65]std.Thread = undefined;
    if (cfg.readers > 64) die("--readers at most 64", .{});
    const io0 = procIo();
    const syncs0 = cwal.fault.syncs;
    const wal0 = walBytes(dir);
    const db0 = dbBytes(dir);
    shared.start_ns = cwal.monotonicNs() + 200_000_000;
    shared.end_ns = shared.start_ns + @as(u64, @intFromFloat(cfg.duration_s * 1e9));
    for (rjobs, 0..) |*j, i| {
        j.* = .{ .shared = &shared, .seed = 100 + i };
        threads[i] = std.Thread.spawn(.{}, readerThread, .{j}) catch die("spawn", .{});
    }
    threads[cfg.readers] = std.Thread.spawn(.{}, writerThread, .{&wjob}) catch die("spawn", .{});

    // Monitor: peak RSS and WAL size, and interval reports.
    var peak_rss: u64 = 0;
    var peak_wal: u64 = wal0;
    var last_report = shared.start_ns;
    var prev_w: Hist = .{};
    var prev_r: Hist = .{};
    var prev_wops: u64 = 0;
    var prev_rops: u64 = 0;
    const prev_reader = std.heap.c_allocator.alloc(u64, cfg.readers) catch die("oom", .{});
    defer std.heap.c_allocator.free(prev_reader);
    @memset(prev_reader, 0);
    while (cwal.monotonicNs() < shared.end_ns + 50_000_000) {
        _ = c.usleep(100_000);
        peak_rss = @max(peak_rss, rssBytes());
        peak_wal = @max(peak_wal, walBytes(dir));
        const now = cwal.monotonicNs();
        if (cfg.report_s > 0 and now >= last_report + @as(u64, @intFromFloat(cfg.report_s * 1e9))) {
            const w = wjob.all.snapshot();
            var r: Hist = .{};
            var rops: u64 = 0;
            var min_reader: u64 = std.math.maxInt(u64);
            for (rjobs, prev_reader) |*j, *prev| {
                const s = j.all.snapshot();
                r.merge(&s);
                const n = j.ops.load(.monotonic);
                rops += n;
                min_reader = @min(min_reader, n - prev.*);
                prev.* = n;
            }
            const dw = w.minus(&prev_w);
            const dr = r.minus(&prev_r);
            const secs = @as(f64, @floatFromInt(now - last_report)) / 1e9;
            const wops = wjob.ops.load(.monotonic);
            out("interval t_s={d:.0} write_ops_s={d:.1} write_p50_us={d:.0} write_p99_us={d:.0} read_ops_s={d:.1} read_p50_us={d:.0} read_p99_us={d:.0} min_reader_ops_s={d:.1} rss_mb={d:.1} wal_mb={d:.1} db_mb={d:.1} ckpt_complete={d} fsyncs={d}\n", .{
                @as(f64, @floatFromInt(now - shared.start_ns)) / 1e9, @as(f64, @floatFromInt(wops - prev_wops)) / secs, us(dw.pct(0.5)),  us(dw.pct(0.99)),
                @as(f64, @floatFromInt(rops - prev_rops)) / secs,     us(dr.pct(0.5)),                                  us(dr.pct(0.99)), @as(f64, @floatFromInt(min_reader)) / secs,
                mb(rssBytes()),                                       mb(walBytes(dir)),                                mb(dbBytes(dir)), wjob.ckpt_complete.load(.monotonic),
                cwal.fault.syncs - syncs0,
            });
            prev_w = w;
            prev_r = r;
            prev_wops = wops;
            prev_rops = rops;
            last_report = now;
        }
    }
    shared.stop.store(true, .monotonic);
    for (threads[0 .. cfg.readers + 1]) |t| t.join();
    const wall = @as(f64, @floatFromInt(@max(shared.end_ns, cwal.monotonicNs()) - shared.start_ns)) / 1e9;
    const run_end = cwal.monotonicNs();

    // Bring the WAL modes to the same end state as the journal mode: every
    // change in the database files. Counted in the bytes, not the latency.
    const conn = wjob.conn.?;
    if (cfg.mode != .journal) _ = c.sqlite3_wal_checkpoint_v2(conn.db, null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null);
    const final_ckpt_ms = @as(f64, @floatFromInt(cwal.monotonicNs() - run_end)) / 1e6;
    const io1 = procIo();
    const syncs = cwal.fault.syncs - syncs0;
    const db1 = dbBytes(dir);
    conn.close();

    var ru: c.struct_rusage = undefined;
    _ = c.getrusage(c.RUSAGE_SELF, &ru);
    var rall: Hist = .{};
    var rops: u64 = 0;
    var rretries: u64 = 0;
    var rbytes: u64 = 0;
    var rcpu: u64 = 0;
    var snaps: u64 = 0;
    var wwait: u64 = 0;
    var rmin: u64 = std.math.maxInt(u64);
    var rmax: u64 = 0;
    var rworst: u64 = 0;
    for (rjobs) |*j| {
        rmin = @min(rmin, j.ops.load(.monotonic));
        rmax = @max(rmax, j.ops.load(.monotonic));
        rworst = @max(rworst, j.all.max);
        rall.merge(&j.all);
        rops += j.ops.load(.monotonic);
        rretries += j.retries;
        rbytes += j.bytes;
        rcpu += j.cpu_ns;
        snaps += j.snapshot_reads;
        wwait += j.window_wait_ns;
    }
    const tag = .{ @tagName(cfg.mode), @tagName(cfg.scenario) };
    inline for (@typeInfo(WriterOps).@"enum".field_names, 0..) |name, i| {
        const h = &wjob.hists[i];
        if (h.n != 0) out("op mode={s} scenario={s} side=write kind={s} n={d} p50_us={d:.0} p95_us={d:.0} p99_us={d:.0} max_us={d:.0} mean_us={d:.0}\n", tag ++ .{ name, h.n, us(h.pct(0.5)), us(h.pct(0.95)), us(h.pct(0.99)), us(h.max), us(h.sum / h.n) });
    }
    inline for (@typeInfo(ReaderOps).@"enum".field_names, 0..) |name, i| {
        var h: Hist = .{};
        for (rjobs) |*j| h.merge(&j.hists[i]);
        if (h.n != 0) out("op mode={s} scenario={s} side=read kind={s} n={d} p50_us={d:.0} p95_us={d:.0} p99_us={d:.0} max_us={d:.0} mean_us={d:.0}\n", tag ++ .{ name, h.n, us(h.pct(0.5)), us(h.pct(0.95)), us(h.pct(0.99)), us(h.max), us(h.sum / h.n) });
    }
    const w = &wjob.all;
    const wops = wjob.ops.load(.monotonic);
    const payload = wjob.payload.load(.monotonic);
    const cpu_total = @as(f64, @floatFromInt(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec)) + @as(f64, @floatFromInt(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec)) / 1e6;
    out("summary mode={s} scenario={s} target_write_ops_s={d:.1} write_ops_s={d:.2} write_p50_us={d:.0} write_p95_us={d:.0} write_p99_us={d:.0} write_max_us={d:.0} max_lag_ms={d:.1} write_retries={d} target_read_ops_s={d:.1} read_ops_s={d:.1} read_p50_us={d:.0} read_p95_us={d:.0} read_p99_us={d:.0} read_max_us={d:.0} read_retries={d} read_mb_s={d:.1} snapshot_reads={d} reader_window_wait_ms={d:.1}\n", tag ++ .{
        cfg.rate,                                             @as(f64, @floatFromInt(wops)) / wall, us(w.pct(0.5)),    us(w.pct(0.95)),    us(w.pct(0.99)),    us(w.max),    @as(f64, @floatFromInt(wjob.max_lag_ns)) / 1e6, wjob.retries,
        cfg.read_rate * @as(f64, @floatFromInt(cfg.readers)), @as(f64, @floatFromInt(rops)) / wall, us(rall.pct(0.5)), us(rall.pct(0.95)), us(rall.pct(0.99)), us(rall.max), rretries,                                       mb(rbytes) / wall,
        snaps,                                                @as(f64, @floatFromInt(wwait)) / 1e6,
    });
    out("resources mode={s} scenario={s} wall_s={d:.1} cpu_s={d:.2} writer_cpu_s={d:.2} reader_cpu_s={d:.2} ckpt_s={d:.2} final_ckpt_ms={d:.0} max_rss_mb={d:.1} peak_rss_mb={d:.1} payload_mb={d:.2} wchar_mb={d:.1} write_bytes_mb={d:.1} write_amp={d:.2} disk_write_amp={d:.2} fsyncs={d} fsyncs_per_write_op={d:.2} peak_wal_mb={d:.1} db_growth_mb={d:.1}\n", tag ++ .{
        wall,                                                                                                                   cpu_total,                 @as(f64, @floatFromInt(wjob.cpu_ns)) / 1e9,                                           @as(f64, @floatFromInt(rcpu)) / 1e9,
        @as(f64, @floatFromInt(wjob.ckpt_ns)) / 1e9,                                                                            final_ckpt_ms,             @as(f64, @floatFromInt(ru.unnamed_0.ru_maxrss)) / 1024.0,                             mb(peak_rss),
        mb(payload),                                                                                                            mb(io1.wchar - io0.wchar), mb(io1.write_bytes - io0.write_bytes),                                                if (payload != 0) @as(f64, @floatFromInt(io1.wchar - io0.wchar)) / @as(f64, @floatFromInt(payload)) else 0,
        if (payload != 0) @as(f64, @floatFromInt(io1.write_bytes - io0.write_bytes)) / @as(f64, @floatFromInt(payload)) else 0, syncs,                     if (wops != 0) @as(f64, @floatFromInt(syncs)) / @as(f64, @floatFromInt(wops)) else 0, mb(peak_wal),
        mb(db1 -| db0),
    });
    // Starvation: an open-loop reader that falls behind its schedule shows
    // as fewer operations than offered.
    const offered_reads: f64 = if (cfg.read_rate > 0) cfg.read_rate * cfg.duration_s else 0;
    out("health mode={s} scenario={s} readers={d} ckpt_runs={d} ckpt_complete={d} reader_ops_min={d} reader_ops_max={d} reader_ops_offered={d:.0} reader_worst_us={d:.0} writer_ops={d} writer_ops_offered={d:.0}\n", tag ++ .{
        cfg.readers, wjob.ckpt_runs, wjob.ckpt_complete.load(.monotonic), if (cfg.readers == 0) 0 else rmin, rmax, offered_reads, us(rworst), wops, cfg.rate * cfg.duration_s,
    });
    std.heap.c_allocator.free(rjobs);
}

// ---------------------------------------------------------------------------
// Integrity check after a run
// ---------------------------------------------------------------------------

/// SQLite's integrity and foreign-key checks on every member, then the
/// cross-file invariants the writer's transactions maintain. A torn
/// cross-file commit breaks one of the latter.
pub fn check(dir: []const u8, mode: Mode) void {
    var bufs: [files.len][1024]u8 = undefined;
    const l = paths(dir, &bufs);
    const conn = Conn.open(&l, .{ .mode = connMode(mode), .role = .writer }) catch |e| die("wcheck open: {s}", .{@errorName(e)});
    var failures: u64 = 0;
    for (0..files.len) |m| {
        var buf: [64]u8 = undefined;
        const ic = Stmt.prep(conn, bufPrintZ(&buf, "pragma {s}.integrity_check", .{Conn.schemaName(m)}));
        while (ic.step() catch die("busy", .{})) {
            const t = std.mem.span(c.sqlite3_column_text(ic.s, 0));
            if (!std.mem.eql(u8, t, "ok")) {
                out("wcheck FAIL integrity {s}: {s}\n", .{ files[m], t });
                failures += 1;
            }
        }
        ic.finalize();
        const fk = Stmt.prep(conn, bufPrintZ(&buf, "pragma {s}.foreign_key_check", .{Conn.schemaName(m)}));
        var n: u64 = 0;
        while (fk.step() catch die("busy", .{})) n += 1;
        fk.finalize();
        if (n != 0) {
            out("wcheck FAIL foreign keys {s}: {d} rows\n", .{ files[m], n });
            failures += 1;
        }
    }
    const invariants = [_]struct { name: []const u8, sql: [:0]const u8 }{
        .{ .name = "doc without its object", .sql = "select count(*) from main.docs d where d.object_id is not null and not exists (select 1 from m1._zova_objects o where o.object_id = d.object_id)" },
        .{ .name = "big object row without its object", .sql = "select count(*) from main.bigs b where not exists (select 1 from m1._zova_objects o where o.object_id = b.object_id)" },
        .{ .name = "object with missing or extra chunks", .sql = "select count(*) from m1._zova_objects o where o.chunk_count != (select count(*) from m1._zova_object_chunks oc where oc.object_id = o.object_id) or o.size_bytes != (select coalesce(sum(size_bytes), 0) from m1._zova_object_chunks oc where oc.object_id = o.object_id)" },
        .{ .name = "object not referenced by a row", .sql = "select count(*) from m1._zova_objects o where not exists (select 1 from main.docs d where d.object_id = o.object_id) and not exists (select 1 from main.bigs b where b.object_id = o.object_id)" },
        .{ .name = "ingested doc without its vector", .sql = "select count(*) from main.docs d where d.object_id is not null and not exists (select 1 from m2._zova_vectors v where v.collection_key = 1 and v.vector_id = 'doc-' || d.id)" },
        .{ .name = "vector without its doc", .sql = "select count(*) from m2._zova_vectors v where not exists (select 1 from main.docs d where d.id = cast(substr(v.vector_id, 5) as integer))" },
    };
    for (invariants) |inv| {
        const st = Stmt.prep(conn, inv.sql);
        const n = st.scalar() catch die("busy", .{});
        st.finalize();
        if (n != 0) {
            out("wcheck FAIL {s}: {d}\n", .{ inv.name, n });
            failures += 1;
        }
    }
    // Pairs: every ('doc', id) and ('big', id) key names an existing row,
    // and every ingested doc has its ('doc', id) pair.
    {
        const pairs = Stmt.prep(conn, "select namespace, key from m4._zova_kv where namespace in (x'646f63', x'626967')");
        const doc = Stmt.prep(conn, "select count(*) from main.docs where id = ?1");
        const big = Stmt.prep(conn, "select count(*) from main.bigs where id = ?1");
        var orphans: u64 = 0;
        var doc_pairs: u64 = 0;
        while (pairs.step() catch die("busy", .{})) {
            const k = pairs.colBlob(1);
            if (k.len != 8) {
                orphans += 1;
                continue;
            }
            const id = std.mem.readInt(i64, k[0..8], .big);
            const is_doc = std.mem.eql(u8, pairs.colBlob(0), "doc");
            const st = if (is_doc) doc else big;
            st.int(1, id);
            if ((st.scalar() catch die("busy", .{})) == 0) orphans += 1;
            if (is_doc) doc_pairs += 1;
        }
        pairs.finalize();
        doc.finalize();
        big.finalize();
        if (orphans != 0) {
            out("wcheck FAIL pair without its row: {d}\n", .{orphans});
            failures += 1;
        }
        // Ingested docs each wrote a pair; updates may add pairs for docs
        // without objects, so at least that many.
        const ingested = Stmt.prep(conn, "select count(*) from main.docs where object_id is not null");
        const n: u64 = @intCast(ingested.scalar() catch die("busy", .{}));
        ingested.finalize();
        if (doc_pairs < n) {
            out("wcheck FAIL ingested docs {d} > doc pairs {d}\n", .{ n, doc_pairs });
            failures += 1;
        }
    }
    var counts: [6]i64 = undefined;
    const count_sql = [_][:0]const u8{ "select count(*) from main.docs", "select count(*) from m1._zova_objects", "select count(*) from m2._zova_vectors", "select count(*) from m3._zova_graph_nodes", "select count(*) from m3._zova_graph_edges", "select count(*) from m4._zova_kv" };
    for (count_sql, &counts) |sql, *n| {
        const st = Stmt.prep(conn, sql);
        n.* = st.scalar() catch die("busy", .{});
        st.finalize();
    }
    conn.close();
    if (failures != 0) die("wcheck {d} failures", .{failures});
    out("wcheck ok docs={d} objects={d} vectors={d} nodes={d} edges={d} pairs={d}\n", .{ counts[0], counts[1], counts[2], counts[3], counts[4], counts[5] });
}
