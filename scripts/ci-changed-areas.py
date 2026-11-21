#!/usr/bin/env python3
"""Decide which CI jobs a pull request needs from the paths it changes.

    git diff --name-only --no-renames HEAD^1 HEAD | ci-changed-areas.py
    ci-changed-areas.py --all

Prints one `<job>=true|false` line per job group, for $GITHUB_OUTPUT.
Documentation enables none: the checks that read it (check-versions.sh and
test_python_platform_matrix.py) run in the CI job that always runs. Any other
path outside bindings/ counts as core and enables every job, because the Zig
core, scripts and workflows can affect any binding. --all enables every job,
for pushes.
"""

import sys

JOBS = ("native", "rust", "rust_artifact", "python", "javascript", "go", "plugin_packages", "wasm")

# Which job groups a change under each prefix needs. Python and JavaScript
# wrap the safe Rust crate, and the plugin packages exercise every native
# binding.
AREAS = {
    "bindings/rust/": {"rust", "rust_artifact", "python", "javascript", "plugin_packages"},
    "bindings/python/": {"python", "plugin_packages"},
    "bindings/javascript/": {"javascript", "plugin_packages"},
    "bindings/go/": {"go", "plugin_packages"},
    "bindings/wasm/": {"wasm"},
    ".github/workflows/wasm.yml": {"wasm"},
}
DOCS = ("docs/", "notes/", ".github/release-notes/")


def is_docs(path):
    return path.startswith(DOCS) or ("/" not in path and path.endswith(".md"))


def jobs_for(paths):
    needed = set()
    for path in paths:
        if is_docs(path):
            continue
        prefix = next((p for p in AREAS if path.startswith(p)), None)
        if prefix is None:
            return set(JOBS)
        needed |= AREAS[prefix]
    return needed


def main(argv):
    if argv == ["--all"]:
        needed = set(JOBS)
    elif not argv:
        paths = [line.strip() for line in sys.stdin if line.strip()]
        for path in paths:
            print(f"changed: {path}", file=sys.stderr)
        needed = jobs_for(paths)
    else:
        raise SystemExit("usage: ci-changed-areas.py [--all] < changed-paths")
    for job in JOBS:
        print(f"{job}={'true' if job in needed else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
