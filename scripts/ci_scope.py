"""Select CI conservatively and reject accidental skips in the final gate."""

import argparse
import json
from pathlib import Path, PurePosixPath
import subprocess
import sys


GROUPS = ("full", "native", "rust", "go", "python", "javascript", "wasm")
BINDINGS = ("rust", "go", "python", "javascript", "wasm")
JOB_GROUPS = {
    "changes": None,
    "static-check": None,
    "rust-artifact": "rust",
    "wasm": "wasm",
    "zig": "native",
    "windows-extensions": "native",
    "sqlite-size": "native",
    "sqlite-invariants": "native",
    "generated-c": "native",
    "rust": "rust",
    "go": "go",
    "python": "python",
    "javascript-build": "javascript",
    "javascript": "javascript",
}


def full_scope():
    return dict.fromkeys(GROUPS, True)


def classify(paths, event="pull_request", ref=""):
    # Releases and post-merge main always run the complete gate.
    if (not paths or event not in ("pull_request", "push")
            or (event == "push" and (ref == "main" or ref.startswith("release/")
                                      or ref.startswith("refs/tags/")))):
        return full_scope()
    scope = dict.fromkeys(GROUPS, False)
    for path in paths:
        parts = PurePosixPath(path).parts
        if path in ("README.md", "CONTRIBUTING.md", "CHANGELOG.md"):
            continue
        if path.startswith(("docs/", "notes/", ".github/release-notes/")) and path.endswith(".md"):
            continue
        if len(parts) < 3 or parts[0] != "bindings" or parts[1] not in BINDINGS:
            return full_scope()
        if path.endswith(".md"):
            continue
        # Version/dependency metadata and generated native inputs may affect
        # several packages and release tooling, so never narrow these changes.
        if (PurePosixPath(path).name in ("Cargo.toml", "package.json", "pyproject.toml", "go.mod")
                or "native" in parts or "generated" in parts):
            return full_scope()
        binding = parts[1]
        scope[binding] = True
        if binding == "rust":
            # Python/JS consume Rust; WASM's version gate verifies its snapshot.
            for consumer in ("python", "javascript", "wasm"):
                scope[consumer] = True
    return scope


def changed_paths(base, head):
    # Do not interpolate refs into shell commands; --verify also rejects a
    # missing/zero base (new branch), which conservatively requests full CI.
    for revision in (base, head):
        subprocess.run(["git", "rev-parse", "--verify", "--end-of-options", revision + "^{commit}"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    result = subprocess.run(
        ["git", "diff", "--name-only", "--no-renames", "-z", base, head, "--"],
        check=True, capture_output=True,
    )
    return [path.decode("utf-8") for path in result.stdout.split(b"\0") if path]


def gate_errors(scope, needs):
    if set(scope) != set(GROUPS) or any(type(value) is not bool for value in scope.values()):
        raise ValueError("CI scope must contain every group as a boolean")
    if scope["full"] and not all(scope.values()):
        raise ValueError("Full CI cannot disable any group")
    errors = []
    for job in set(needs) - set(JOB_GROUPS):
        errors.append(f"{job}: no coverage policy defined")
    for job, group in JOB_GROUPS.items():
        status = needs.get(job, {}).get("result", "missing")
        required = group is None or scope[group]
        if status == "success" or (status == "skipped" and not required):
            continue
        errors.append(f"{job}: {status} (required={required})")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    selection = commands.add_parser("classify")
    selection.add_argument("--base", required=True)
    selection.add_argument("--head", required=True)
    selection.add_argument("--event", required=True)
    selection.add_argument("--ref", required=True)
    selection.add_argument("--output", type=Path, required=True)
    gate = commands.add_parser("gate")
    gate.add_argument("--scope", required=True)
    gate.add_argument("--needs", required=True)
    args = parser.parse_args()
    if args.command == "classify":
        try:
            paths = changed_paths(args.base, args.head)
            scope = classify(paths, args.event, args.ref)
        except (subprocess.CalledProcessError, UnicodeError):
            print("Unable to classify the complete diff; running full CI", file=sys.stderr)
            scope = full_scope()
        with args.output.open("a", encoding="utf-8") as output:
            for group, selected in scope.items():
                output.write(f"{group}={str(selected).lower()}\n")
            output.write("scope=" + json.dumps(scope, separators=(",", ":")) + "\n")
        print(json.dumps(scope, sort_keys=True))
        return 0
    try:
        errors = gate_errors(json.loads(args.scope), json.loads(args.needs))
    except (ValueError, TypeError, AttributeError) as error:
        print(f"Invalid CI gate inputs: {error}", file=sys.stderr)
        return 1
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("CI gate passed: selected checks succeeded; skips match the coverage policy")
    return 0


if __name__ == "__main__":
    sys.exit(main())
