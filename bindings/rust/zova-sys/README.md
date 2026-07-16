# zova-sys

`zova-sys` is the raw Rust FFI crate for Zova's C ABI.

Most Rust users should depend on the safe `zova` crate instead. Use
`zova-sys` when you need direct access to the C request structs and exported
functions from `include/zova.h`.

## Native Build

By default, crates.io builds compile the bundled generated C snapshot with the
platform C compiler and link it into the Rust crate. You need:

- Rust
- a C compiler/linker for your platform

Advanced users can point the build script at an existing native build:

```sh
ZOVA_LIB_DIR=/path/to/lib ZOVA_INCLUDE_DIR=/path/to/include cargo build
```

Build order is:

1. `ZOVA_LIB_DIR` / `ZOVA_INCLUDE_DIR` if provided.
2. Bundled generated C compiled with the platform C compiler at `-O2`.

Inside the Zova repository, Zig is also used to regenerate the bundled C
snapshot. The generated C is compiler output, not a human-authored API.

Zova 0.24 uses `.zova` format 8 and does not migrate format-7 databases in
place. Keep a compatible backup or use a 0.23.x build to export data before
creating a format-8 database.

## Safety

This crate exposes raw C ABI declarations. It does not manage pointer lifetime,
owned buffers, or error mapping for you. The safe `zova` crate handles those
details.

`zova-sys` exposes the v0.24 low-level Rust surface for SQL callbacks.
It exposes the raw C ABI structs and functions for scalar SQL registration and
trusted `.zovaext` bundle loading. Callbacks are unsafe FFI: argument pointers
are borrowed for the duration of the call, text/blob/error result bytes are
copied by Zova before SQLite observes them, and callbacks must not re-enter the
same `zova_database` handle.

The safe Rust `zova` crate does not yet wrap app-defined SQL callbacks or
dynamic extension bundle loading. Go and Python callback APIs are also deferred.
