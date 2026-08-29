# Minimal Zig Bridge

This example shows the bridge shape for a C or C++ host that wants Zova-owned
connections plus a custom Zig extension registry.

It is not a new public Zova API. The host links a small Zig object or library
that imports Zova, defines an extension, registers SQL in the extension
`register_sql` hook, and exposes a narrow C-callable function back to the host.

The example extension is named `codebase_memory_demo` because this shape matches
the needs of codebase-memory-style applications, but it does not add any
codebase-memory-specific behavior to Zova.

## Build Object

`build-obj` is the simplest downstream bridge artifact. The host links the
resulting object directly:

```sh
zig build-obj \
  -fPIC \
  -lc \
  -femit-bin=zig_bridge.o \
  --name zova_bridge \
  --dep zova \
  -Mroot=examples/zig_bridge/bridge.zig \
  -I vendor/sqlite3.53.4 \
  -Mzova=src/root.zig
```

The `-I vendor/sqlite3.53.4` include path is required because importing
`zova.sqlite` performs a C import of `sqlite3.h`.

Check that the artifact is non-empty and exports the C-callable bridge symbol:

```sh
nm zig_bridge.o | grep zova_bridge_smoke
```

## Build Static Library

`build-lib -static` should produce a non-empty archive with the exported bridge
symbol. Treat the archive as invalid if it is empty or the symbol is missing:

```sh
zig build-lib \
  -static \
  -fPIC \
  -lc \
  -femit-bin=libzig_bridge.a \
  --name zova_bridge \
  --dep zova \
  -Mroot=examples/zig_bridge/bridge.zig \
  -I vendor/sqlite3.53.4 \
  -Mzova=src/root.zig

nm libzig_bridge.a | grep zova_bridge_smoke
```

For dynamic `.zovaext` packages, prefer the experimental CLI builder:

```sh
zova extension scaffold ./sample_ext --name sample_ext --version 0.1.0
zova extension build ./sample_ext
zova extension pack ./sample_ext --out ./sample_ext.zovaext
zova extension verify --smoke ./sample_ext.zovaext
```

## Host Contract

The exported function:

```c
int zova_bridge_smoke(const char *db_path);
```

creates or opens a `.zova` database with the custom Zig registry, installs the
example extension if needed, checks it, and runs:

```sql
select zova_bridge_demo_value()
```

Real bridges should expose only the narrow operations the host needs. Do not
pass raw `sqlite3 *` handles across this boundary unless your application owns
all of the invariants that Zova normally protects.
