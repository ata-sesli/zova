//! C ABI test entrypoint.
//!
//! The ABI implementation tests currently live beside the internal helpers so
//! they can exercise non-exported conversion and validation paths. This module
//! keeps `src/c_api.zig` free of test bodies while still pulling those tests
//! into the `c-api-test` build root.

const internal = @import("c_api_internal.zig");

test {
    _ = internal;
}
