#!/usr/bin/env python3
"""Fail when a binding neither calls a C ABI function nor allow-lists it.

Every function declared in include/zova.h must be referenced by the sources
of each binding that calls the C ABI directly, or be listed with a reason in
scripts/abi-coverage-allowlist.json. Allow-list entries that a binding now
references, or that name no declared function, also fail, so the list cannot
go stale.

Python and JavaScript wrap the safe Rust crate rather than the C ABI, so
they are covered through the Rust check only.

    python3 scripts/check-abi-coverage.py [repository-root]
"""

import json
from pathlib import Path
import re
import sys


# Sources that hold each binding's C ABI calls. Tests are excluded: a call
# from a test does not expose the function to users.
BINDINGS = {
    "rust": ["bindings/rust/zova/src/**/*.rs"],
    "go": ["bindings/go/*.go"],
    "wasm": ["bindings/wasm/native/*.c", "bindings/wasm/native/*.zig"],
}
ALLOWLIST = "scripts/abi-coverage-allowlist.json"
DECLARATION = re.compile(r"^(?!typedef\b)[A-Za-z_][\w \t*]*?\b(zova_\w+)\s*\(", re.M)


def header_functions(header: str) -> list[str]:
    """Names of the functions declared in a C header, sorted."""
    without_comments = re.sub(r"/\*.*?\*/", "", header, flags=re.S)
    without_comments = re.sub(r"//[^\n]*", "", without_comments)
    return sorted(set(DECLARATION.findall(without_comments)))


def binding_sources(root: Path, patterns: list[str]) -> str:
    text = []
    for pattern in patterns:
        for path in sorted(root.glob(pattern)):
            if path.name.endswith("_test.go"):
                continue
            text.append(path.read_text())
    return "\n".join(text)


def referenced(functions: list[str], source: str) -> set[str]:
    words = set(re.findall(r"\bzova_\w+\b", source))
    return {name for name in functions if name in words}


def check(functions: list[str], sources: dict[str, str], allowlist: dict[str, dict[str, str]]) -> list[str]:
    """Problems found, one line each; empty when every binding is covered."""
    problems = []
    declared = set(functions)
    for binding in sorted(set(allowlist) - set(sources)):
        problems.append(f"{ALLOWLIST}: unknown binding {binding!r}")
    for binding, source in sorted(sources.items()):
        allowed = allowlist.get(binding, {})
        found = referenced(functions, source)
        for name in functions:
            if name not in found and name not in allowed:
                problems.append(f"{binding}: {name} is neither referenced nor allow-listed")
        for name, reason in sorted(allowed.items()):
            if name not in declared:
                problems.append(f"{binding}: allow-listed {name} is not declared in include/zova.h")
            elif name in found:
                problems.append(f"{binding}: allow-listed {name} is referenced; remove it from {ALLOWLIST}")
            if not isinstance(reason, str) or not reason.strip():
                problems.append(f"{binding}: allow-listed {name} needs a reason")
    return problems


def main(argv: list[str]) -> int:
    if len(argv) > 2:
        print(__doc__.strip().splitlines()[-1].strip(), file=sys.stderr)
        return 2
    root = Path(argv[1] if len(argv) == 2 else Path(__file__).resolve().parents[1])
    functions = header_functions((root / "include/zova.h").read_text())
    if not functions:
        print("include/zova.h: no function declarations found", file=sys.stderr)
        return 1
    sources = {binding: binding_sources(root, patterns) for binding, patterns in BINDINGS.items()}
    allowlist = json.loads((root / ALLOWLIST).read_text())
    problems = check(functions, sources, allowlist)
    for problem in problems:
        print(problem, file=sys.stderr)
    for binding, source in sorted(sources.items()):
        covered = len(referenced(functions, source))
        print(f"{binding}: {covered} referenced, {len(allowlist.get(binding, {}))} allow-listed, {len(functions)} declared")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
