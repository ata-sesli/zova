# Zova Rust Bindings

This workspace is the first Rust binding slice for Zova.

It contains:

- `zova-sys`: raw C ABI declarations and static linking.
- `zova`: safe Rust wrappers for database lifecycle, SQL prepared statements,
  transactions, and explicit vacuum.

Objects, chunks, vectors, and `ObjectWriter` are intentionally deferred to later
v0.13.x Rust binding slices.

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

The safe Rust wrapper models Zova's one-handle-at-a-time policy with mutable
database and statement methods. `Database` and `Statement` are not `Send` or
`Sync` in this first slice. Open multiple `Database` handles to the same file
for parallel work and let SQLite locking decide concurrency.

## Example

```rust
use zova::{Database, Step};

let mut db = Database::create("example.zova")?;
db.exec("create table notes(id integer primary key, body text not null)")?;

let mut insert = db.prepare("insert into notes(body) values (?1)")?;
insert.bind_text(1, "hello from Rust")?;
assert_eq!(insert.step()?, Step::Done);
```
