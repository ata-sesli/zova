# v0.21.2 Checklist: Raw f16 and i8 Vectors

## Goal

Add first-class raw vector element types for `f16` and `i8`, while preserving the current `f32` API and file compatibility.

This is not automatic quantization. Callers provide values in the declared element type, and Zova stores/searches those values directly.

## Scope

- [x] Support `f32`, `f16`, and `i8` as vector collection element types.
- [x] Keep `f32` as the default element type.
- [x] Keep existing f32 public APIs working unchanged.
- [x] Add typed vector APIs where the current `float *` ABI cannot represent raw `f16` or `i8`.
- [x] Exclude `i4` from this release.
- [x] Exclude automatic quantization, scales, zero-points, and reranking from this release.

## Core Zig API

- [x] Add `VectorElementType = enum { f32, f16, i8 }`.
- [x] Add `element_type` to `VectorCollectionOptions`.
- [x] Add `element_type` to `VectorCollectionInfo`.
- [x] Extend collection creation to write the requested `element_type` instead of hardcoded `'f32'`.
- [x] Extend collection loading to accept `f32`, `f16`, and `i8`.
- [x] Keep existing f32-only convenience APIs intact.
- [x] Add typed vector value/input representation for new APIs.
- [x] Decide whether returned typed vectors use a tagged owned union or separate typed getters.

## Storage Encoding

- [x] Keep f32 encoding as little-endian IEEE 754 binary32.
- [x] Store f16 as little-endian IEEE 754 binary16 bits.
- [x] Store i8 as raw signed bytes.
- [x] Replace `vectorByteLen(dimensions)` with element-type-aware byte length:
  - [x] `f32`: `dimensions * 4`
  - [x] `f16`: `dimensions * 2`
  - [x] `i8`: `dimensions`
- [x] Validate encoded blob lengths by element type.
- [x] Reject invalid f16/f32 values where appropriate for vector input and stored-vector corruption checks.

## Distance Math

- [x] Refactor distance calculation to dispatch by `VectorElementType`.
- [x] Widen f16 values to f32/f64 for distance math.
- [x] Widen i8 values to f64 for distance math.
- [x] Support `cosine`, `l2`, and `dot` for all three element types.
- [x] Preserve cosine zero-vector rejection for all element types.
- [x] Keep result ordering and tie behavior stable.
- [x] Add tests for known-distance fixtures across f32, f16, and i8.

## SQL Helpers

- [x] Update `zova_vector_distance` and `zova_vector_distance_by_id` behavior for typed collections.
- [x] Update `zova_vector_search` virtual table behavior for typed collections.
- [x] Keep existing f32 SQL blob behavior compatible.
- [x] Decide whether ad hoc typed query blobs need a new SQL helper rather than overloading existing f32 helpers.
- [x] Add SQL tests for f16 and i8 search/order/distance.

## C ABI

- [x] Add `zova_vector_element_type`.
- [x] Add typed vector value representation using raw bytes or tagged pointers.
- [x] Treat f16 ABI values as `uint16_t` bit patterns, not C `_Float16`.
- [x] Treat i8 ABI values as `int8_t`.
- [x] Add typed collection creation.
- [x] Add typed put/get/search APIs.
- [x] Keep existing f32 structs and functions as compatibility wrappers.
- [x] Update generated C header.
- [x] Update C ABI null-pointer and shape validation tests.
- [x] Update C ABI vector lifecycle/search tests for f16 and i8.

## Rust Binding

- [x] Add `VectorElementType`.
- [x] Add typed collection options.
- [x] Add typed vector input/output API.
- [x] Keep existing `&[f32]` APIs.
- [x] Represent f16 as `u16` bits initially, or add an optional ergonomic wrapper later.
- [x] Add Rust tests for f16 and i8 roundtrip and search.

## Go Binding

- [x] Add `VectorElementType`.
- [x] Add typed collection options.
- [x] Add typed vector input/output API.
- [x] Keep existing `[]float32` APIs.
- [x] Represent f16 as `[]uint16` bits.
- [x] Represent i8 as `[]int8`.
- [x] Add Go tests for f16 and i8 roundtrip and search.

## Python Binding

- [x] Add element type to collection options.
- [x] Add typed put/get/search APIs.
- [x] Keep existing float-list APIs.
- [x] Represent i8 as Python integers or bytes.
- [x] Represent f16 as raw `uint16` bits first; optionally support NumPy `float16` when available.
- [x] Add Python tests for f16 and i8 roundtrip and search.

## Validation And Format

- [x] Update Zova schema validation to accept `f32`, `f16`, and `i8`.
- [x] Update deep/operational verification to validate typed vector rows.
- [x] Update corruption tests for wrong element type and wrong blob length.
- [x] Confirm backup, compact, restore, and reopen preserve element type and values.
- [x] Confirm bound/split vector stores preserve element type and values.
- [x] Confirm SQLite-to-Zova conversion remains compatible with existing f32 behavior.

## Docs And Examples

- [x] Document vector element types.
- [x] Document f16 ABI as raw IEEE 754 binary16 `uint16_t` bits.
- [x] Document i8 as raw signed int8 values.
- [x] State clearly that this release does not perform quantization.
- [x] Add one example per binding that creates and searches an i8 collection.
- [x] Add one f16 example where useful.

## Release Checks

- [x] Run Zig tests.
- [x] Run C ABI header smoke test.
- [x] Run generated C header check.
- [x] Run Rust binding tests.
- [x] Run Python binding tests.
- [x] Run Go binding tests.
- [x] Run release check script.
- [x] Update release notes/docs with raw f16 and i8 vector support. The repo has no standalone changelog file; README and binding docs were updated.
