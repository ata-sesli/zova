# zova

Safe Rust bindings for Zova.

Zova is a SQLite-backed embedded database for records, objects, and vectors in
one local file. This crate wraps the lower-level `zova-sys` C ABI crate with
Rust ownership, error handling, and safe containers.

## Install

```toml
[dependencies]
zova = "0.20.0"
```

The crate builds Zova's native C ABI through `zova-sys`, so users need Rust,
Zig 0.16.0 or newer, and a working C compiler/linker.

## What It Covers

- database create/open/convert
- SQL exec and prepared statements
- transactions and savepoints
- backup, compact copy, and restore
- objects, chunks, manifests, range reads, and `ObjectWriter`
- vector collections, CRUD, exact search, candidate search, thresholds, and
  SQL-native vector search
- same-process transaction-aware app events with `listen` / `notify`
- transparent use of v0.20 bound object/vector stores after open
- `SharedDatabase` for a cloneable, serialized Rust handle

Store create/bind/unbind/split management is CLI/native-Zig-only in v0.20; this
crate keeps the existing object and vector APIs source-compatible.

## Example

```rust
use zova::{Database, Step};

let mut db = Database::create("app.zova")?;
db.exec("create table notes(id integer primary key, body text not null)")?;

let mut insert = db.prepare("insert into notes(body) values (?1)")?;
insert.bind_text(1, "hello from Rust")?;
assert_eq!(insert.step()?, Step::Done);
# Ok::<(), zova::Error>(())
```

See the workspace README and examples for object and vector workflows.

## App Events

`Database::listen` and `Database::notify` provide queue-only, same-process app
events on one open Zova handle. Notifications are explicit and in-memory; they
are delivered after commit and discarded on rollback. They are not durable,
cross-process, replayable, or automatic mutation logs.
