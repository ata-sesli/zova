"""Adapt Zig's generated-C support header for the packaged compilers."""
from pathlib import Path
import sys


def fix_header(header):
    marker = "#else\n#define zig_never_tail zig_never_tail_unavailable"
    if header.count(marker) != 1:
        raise ValueError("expected one Zig never-tail fallback")
    # Zig emits a noinline wrapper around dlsym. GCC must keep the call
    # inside that wrapper so dlsym's hidden return-address argument points
    # into this library. Keep Clang's original attribute unchanged.
    return header.replace(marker, '''#elif defined(zig_gcc)
#define zig_never_tail __attribute__((optimize("no-optimize-sibling-calls"))) zig_never_inline
''' + marker)


if __name__ == "__main__":
    path = Path(sys.argv[1])
    path.write_text(fix_header(path.read_text()))
