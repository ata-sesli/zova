## Summary

What changed?

## Why

What problem does this solve?

## Tests

Commands run:

- [ ] `zig build test`
- [ ] `zig build cli-test`
- [ ] `zig build c-abi-test`
- [ ] `cargo test --workspace --manifest-path bindings/rust/Cargo.toml`
- [ ] `cd bindings/go && go test ./...`
- [ ] `cargo test --manifest-path bindings/python/Cargo.toml`
- [ ] `uv run --isolated --with pytest --directory bindings/python python -m pytest`
- [ ] other:

## Public Surface

Does this change any public behavior?

- [ ] CLI
- [ ] Zig API
- [ ] C ABI
- [ ] Rust binding
- [ ] Go binding
- [ ] Python binding
- [ ] `.zova` file format or private schema
- [ ] docs only

## Generated Or Package Files

- [ ] I changed Zig/C ABI source and ran `sh bindings/rust/zova-sys/tools/sync-native-source.sh`
- [ ] I ran `sh bindings/rust/zova-sys/tools/check-native-source.sh`
- [ ] No generated/package files are relevant

## Notes

Anything reviewers should know?
