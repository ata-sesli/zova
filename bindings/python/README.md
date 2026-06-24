# Zova Python Bindings

This package contains the source-first Python bindings for Zova.

It is a PyO3/maturin extension backed by the safe Rust `zova` binding. It does
not wrap the C ABI directly with `ctypes` or cffi. The native build still uses
Zova's C ABI underneath through the Rust `zova-sys` crate, so Python gets the
same records/objects/vectors foundation without reimplementing the ABI ownership
rules.

## Contents

1. [How It Fits](#how-it-fits)
2. [Local Development](#local-development)
3. [What It Covers](#what-it-covers)
4. [Operational Safety](#operational-safety)
5. [Objects](#objects)
6. [Vectors](#vectors)
7. [SQL-Native Vector Search](#sql-native-vector-search)

## How It Fits

Python users import `zova`. The extension is built with PyO3 and reuses the
safe Rust binding, which in turn links Zova's C ABI.

```mermaid
flowchart LR
    App["Python app"]
    PyPkg["zova Python package"]
    PyO3["PyO3 extension"]
    Rust["Rust zova crate"]
    CABI["libzova_c.a"]
    File["local .zova file"]

    App --> PyPkg
    PyPkg --> PyO3
    PyO3 --> Rust
    Rust --> CABI
    CABI --> File
```

## Local Development

From `bindings/python`:

```sh
uv run --isolated --with maturin --with pytest maturin develop
uv run --isolated --with pytest python -m pytest
```

The native build uses maturin, Cargo, Zig, and the Rust `zova` crate. The
project is source-first: it does not publish wheels to PyPI, and users do not
need to locate a shared C library manually.

The Python API is pre-1.0 and may still change alongside the Rust binding.

## What It Covers

The Python package exposes database lifecycle, conversion, prepared SQL
statements, transactions, explicit vacuum, backup/compact/restore, objects,
streaming object writes, vectors, SQL-native vector search, context managers,
and Zova status exceptions.

One Python `Database` object owns one native handle. The native C ABI serializes
calls on that handle, so one handle is safe but not parallel. Open additional
database handles when an application needs independent concurrent connections;
SQLite locking rules still apply across handles. PyO3 classes remain unsendable
in this release even though the native C ABI serializes its own calls.

Use `Database.open(path, read_only=True)` for read-only handles, and
`Database.set_busy_timeout(milliseconds)` when an application wants SQLite to
wait briefly on cross-handle contention. No nonzero timeout is installed by
default.

Use `Database.last_insert_rowid()`, `Database.changes()`,
`Database.total_changes()`, and `Statement.column_name(index)` for normal
application SQL record helpers. They do not expose or stabilize Zova's private
`_zova_*` tables.

## Operational Safety

Use `backup_to()` for a faithful snapshot, `compact_to()` for a
space-reclaiming copy, and `restore_backup()` to copy a backup into a new
destination file. Destinations must be `.zova` paths and are never overwritten.

```python
with zova.Database.open("app.zova") as db:
    db.backup_to("app.backup.zova")
    db.compact_to("app.compact.zova")

zova.restore_backup("app.backup.zova", "app.restored.zova")
```

By default, each operation verifies the destination after copying. Pass
`verify=False` only when you will verify separately, for example with
`zova check --deep`.

## Objects

The Python binding exposes Zova objects as content-addressed byte values while
keeping application metadata in normal SQL tables.

```python
import zova

with zova.Database.create("app.zova") as db:
    db.exec(
        "create table attachments("
        "id integer primary key, "
        "filename text not null, "
        "object_id blob not null)"
    )

    object_id = db.put_object(b"hello from Zova")

    with db.prepare("insert into attachments(filename, object_id) values (?1, ?2)") as stmt:
        stmt.bind_text(1, "hello.txt")
        stmt.bind_blob(2, bytes(object_id))
        stmt.step()

    assert db.read_object_range(object_id, 0, 5) == b"hello"
```

For large inputs, use `ObjectWriter` so the full object does not have to be held
in memory by the caller:

```python
with db.object_writer() as writer:
    writer.write(b"chunk one")
    writer.write(b"chunk two")
    object_id = writer.finish()
```

If a writer leaves the context without `finish()`, it is cancelled and any
unreferenced chunks written by that writer are cleaned up. Writer operations
follow Zova's object transaction policy and reject active user transactions.

Loose chunks and assembly are also exposed for receive-side workflows:
applications track transfer state in their own SQL tables, call
`put_object_chunk()` for verified chunks, then call
`assemble_object_from_chunks()` when the manifest is complete.

## Vectors

The Python binding exposes Zova vectors with the same model as the Rust binding:
Zova stores numeric vectors in named collections, while application metadata
stays in normal SQL tables.

```python
import zova

with zova.Database.create("vectors.zova") as db:
    db.exec(
        "create table chunks("
        "id text primary key, "
        "document_id text not null, "
        "text text not null, "
        "vector_id text not null)"
    )

    db.create_vector_collection(
        "chunks",
        zova.VectorCollectionOptions(2, zova.VectorMetric.L2),
    )
    db.put_vectors(
        "chunks",
        [
            zova.VectorInput("chunk:1", [0.0, 0.0]),
            zova.VectorInput("chunk:2", [1.0, 0.0]),
        ],
    )

    db.exec(
        "insert into chunks(id, document_id, text, vector_id) values "
        "('c1', 'doc-a', 'first chunk', 'chunk:1'), "
        "('c2', 'doc-a', 'near chunk', 'chunk:2')"
    )

    results = db.search_vectors_in(
        "chunks",
        [0.0, 0.0],
        ["chunk:1", "chunk:2"],
        2,
    )
    for result in results:
        with db.prepare("select text from chunks where vector_id = ?1") as stmt:
            stmt.bind_text(1, result.id)
            stmt.step()
            print(result.id, result.distance, stmt.column_text(0))
```

Search is exact and lower distance is better. Candidate-filtered searches skip
missing ids and deduplicate duplicate candidates. Search-by-id excludes the
source vector. Threshold variants are inclusive, and dot-product thresholds may
be negative because dot distance is `-dot_product`.

Deleting a vector collection removes Zova's private vector rows only. User SQL
metadata rows that reference vector ids are application-owned and remain in
place.

## SQL-Native Vector Search

Zova registers SQL vector functions and the `zova_vector_search` virtual table
on Zova database connections. Bind query vectors as little-endian `f32` blobs
with `encode_f32_le()`:

```python
query = zova.encode_f32_le([0.0, 0.0])

with db.prepare(
    "select c.id, zova_vector_distance('chunks', c.vector_id, ?1) as distance "
    "from chunks as c "
    "where c.document_id = 'doc-a' "
    "order by distance "
    "limit 10"
) as stmt:
    stmt.bind_blob(1, query)
```

Row-to-row distances use `zova_vector_distance_by_id(collection, vector_id,
source_vector_id)`. Collection-wide SQL search uses `zova_vector_search`:

```python
with db.prepare(
    "select c.text, s.distance "
    "from zova_vector_search as s "
    "join chunks as c on c.vector_id = s.vector_id "
    "where s.collection = 'chunks' "
    "and s.query_vector = ?1 "
    "and s.top_k = 10 "
    "order by s.rank"
) as stmt:
    stmt.bind_blob(1, query)
```

Python's built-in `sqlite3` module opens an ordinary SQLite connection and does
not automatically register Zova's SQL functions or virtual table. Use
`zova.Database` for SQL-native vector search in this binding. A future SQLite
loadable extension may make the SQL surface available to external SQLite
connections.
