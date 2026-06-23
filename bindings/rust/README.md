# Zova Rust Bindings

This workspace is the first Rust binding slice for Zova.

It contains:

- `zova-sys`: raw C ABI declarations and static linking.
- `zova`: safe Rust wrappers for database lifecycle, SQL prepared statements,
  transactions, explicit vacuum, objects, chunks, manifests, range reads,
  assembly, `ObjectWriter`, vector collections, vector CRUD, and exact vector
  search.

## Local Build

By default, `zova-sys` builds the local C ABI with:

```sh
zig build c-abi
```

Cargo then links the resulting static library. You can point Cargo at an
existing build instead:

```sh
ZOVA_LIB_DIR=/path/to/lib ZOVA_INCLUDE_DIR=/path/to/include cargo test
```

`ZOVA_INCLUDE_DIR` is accepted for callers that vendor the header alongside the
library. The current hand-written FFI does not run bindgen.

Zova currently requires Zig `0.16.0` or newer for the local C ABI build.

## Handle Policy

The C ABI serializes calls on one `zova_database` handle, so the native handle
can be called from multiple threads safely, one call at a time. The safe Rust
wrapper remains deliberately conservative in this release: `Database` and
`Statement` are not `Send` or `Sync`, and methods use mutable borrows. Open
multiple `Database` handles to the same file for parallel work and let SQLite
locking decide cross-handle concurrency.

Use `Database::open_with_options` with `OpenOptions { read_only: true, .. }`
for read-only handles, and `Database::set_busy_timeout` when an application
wants SQLite to wait briefly on cross-handle contention. No nonzero timeout is
installed by default.

## Example

Records use prepared SQL statements:

```rust
use zova::{Database, Step};

let mut db = Database::create("example.zova")?;
db.exec("create table notes(id integer primary key, body text not null)")?;

let mut insert = db.prepare("insert into notes(body) values (?1)")?;
insert.bind_text(1, "hello from Rust")?;
assert_eq!(insert.step()?, Step::Done);
assert_eq!(db.changes()?, 1);
let rowid = db.last_insert_rowid()?;
```

Use `Database::changes`, `Database::total_changes`,
`Database::last_insert_rowid`, and `Statement::column_name` for normal
application SQL record helpers. They are not a public interface to Zova's
private `_zova_*` tables.

Objects can live beside ordinary SQL metadata:

```rust
use std::convert::TryFrom;
use zova::{Database, ObjectId, Step};

let mut db = Database::create("files.zova")?;
db.exec("create table attachments(id integer primary key, object_id blob not null)")?;

let id = db.put_object(b"file bytes")?;

let mut insert = db.prepare("insert into attachments(object_id) values (?1)")?;
insert.bind_blob(1, id.as_ref())?;
assert_eq!(insert.step()?, Step::Done);
drop(insert);

let mut query = db.prepare("select object_id from attachments where id = 1")?;
assert_eq!(query.step()?, Step::Row);
let stored_id = ObjectId::try_from(query.column_blob(0)?.unwrap().as_slice())?;
drop(query);

assert_eq!(db.get_object(stored_id)?, b"file bytes");
```

For large writes, use `Database::object_writer()` to stream data into Zova
without keeping the complete object in memory. Transfer state, filenames, MIME
types, and application references still belong in user SQL tables.
Writer operations serialize through their parent database handle at the C ABI
boundary and return a Zova transaction error when used inside an active user
transaction.

Vectors follow Zova's SQL-metadata model: store labels, document ids, and other
metadata in ordinary tables, and store numeric vectors in a named collection.

```rust
use zova::{Database, VectorCollectionOptions, VectorInput, VectorMetric};

let mut db = Database::create("vectors.zova")?;
db.exec("create table chunks(id text primary key, vector_id text not null, body text)")?;

db.create_vector_collection(
    "chunks",
    VectorCollectionOptions {
        dimensions: 2,
        metric: VectorMetric::L2,
    },
)?;
db.put_vectors(
    "chunks",
    &[
        VectorInput { id: "v1", values: &[0.0, 0.0] },
        VectorInput { id: "v2", values: &[1.0, 0.0] },
    ],
)?;

let nearest = db.search_vectors("chunks", &[0.0, 0.0], 2)?;
assert_eq!(nearest[0].id, "v1");
```

SQL-native vector search is available through prepared statements too. Bind
query vectors as little-endian `f32` blobs when calling `zova_vector_distance`
or querying `zova_vector_search`; see `zova/examples/vectors.rs` for a complete
metadata join example.
