# Zova Python Bindings

This is the first Python binding slice for Zova.

It is a PyO3/maturin extension backed by the safe Rust `zova` binding. It does
not wrap the C ABI directly with `ctypes` or cffi. The native build still uses
Zova's C ABI underneath through the Rust `zova-sys` crate, so Python gets the
same records/objects/vectors foundation without reimplementing the ABI ownership
rules.

## Local Development

From `bindings/python`:

```sh
uv run --isolated --with maturin --with pytest maturin develop
uv run --isolated --with pytest python -m pytest
```

The native build uses maturin, Cargo, Zig, and the Rust `zova` crate. The
project is source-first in this slice: it does not publish wheels to PyPI and
does not require users to locate a shared C library manually.

The Python API is pre-1.0 and may still change alongside the Rust binding while
the object and vector layers are added.

## Current Surface

This foundation slice exposes database lifecycle, conversion, prepared SQL
statements, transactions, explicit vacuum, context managers, and Zova status
exceptions.

One Python `Database` object owns one native handle. Use one handle at a time,
and open additional database handles when an application needs independent
connections.

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

Vector APIs are planned for a later v0.13.2 slice.
