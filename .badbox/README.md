# Zova Badbox rules

This pack contains deterministic structural tripwires for maintained Zova Zig
production source. Run it from the repository root:

```sh
sh .badbox/check.sh
```

The runner excludes test-only files and three production files currently using
Zig syntax unsupported by Badbox's bundled parser. Keep that exclusion list
explicit and remove entries when the parser accepts them.

The rules use Badbox's relational checks to identify copying text bindings,
statement preparation, allocation, and duplication specifically inside loops.
They also flag direct SQLite wrapper bypasses, repeated same-block
`reset()`-then-`clearBindings()` sequences, and excessive unchecked
`catch unreachable` assumptions.

The ordering rule intentionally matches the literal receiver name `stmt`. This
keeps the evidence object-specific until Badbox can correlate captures across
primary and relational selectors.

Badbox counts lexical syntax sites and checks lexical containment and ordering.
A finding does not prove a runtime cost, leak, unsafe lifetime, bad SQLite plan,
or correctness failure. In particular, these rules do not replace
transaction/fault tests, `EXPLAIN QUERY PLAN`, or performance benchmarks.
Findings are review evidence and do not currently make the Badbox CLI exit
unsuccessfully.

Do not scan vendored SQLite, generated C, native snapshots, fixtures, or build
output with this pack. Add a rule only when it describes a recurring Zova risk
and produces evidence a reviewer can act on.
