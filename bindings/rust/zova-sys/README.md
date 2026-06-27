# zova-sys

`zova-sys` is the raw Rust FFI crate for Zova's C ABI.

Most Rust users should depend on the safe `zova` crate instead. Use
`zova-sys` when you need direct access to the C request structs and exported
functions from `include/zova.h`.

## Native Build

By default, the crate builds Zova's static C ABI library with Zig and links it
into the Rust crate. You need:

- Rust
- Zig 0.16.0 or newer
- a C compiler/linker for your platform

Advanced users can point the build script at an existing native build:

```sh
ZOVA_LIB_DIR=/path/to/lib ZOVA_INCLUDE_DIR=/path/to/include cargo build
```

`ZOVA_SOURCE_DIR=/path/to/zova/source` can be used to build from a separate Zova
source checkout. Without overrides, crates.io builds use the bundled native
source snapshot included in this crate.

## Safety

This crate exposes raw C ABI declarations. It does not manage pointer lifetime,
owned buffers, or error mapping for you. The safe `zova` crate handles those
details.
