"""Adapt Zig C declarations to the Microsoft CRT before packaging."""
from pathlib import Path
import re
import sys


def fix_source(source):
    declarations = {
        "getenv": r"zig_extern uint8_t \*getenv\(uint8_t const \*a0\);",
        "_msize": r"zig_extern uintptr_t _msize\(void const \*a0\);",
    }
    for name, declaration in declarations.items():
        source, count = re.subn(declaration, "", source)
        if count != 1:
            raise ValueError(f"expected one generated declaration for {name}, got {count}")
        source = re.sub(r"\b" + name + r"\b", "zova_generated_" + name, source)
    marker = '#include "zig.h"'
    if source.count(marker) != 1:
        raise ValueError("expected one zig.h include")
    return source.replace(marker, marker + '''
/* The Microsoft CRT defines environ as a macro, but Zig uses it as a field. */
#undef environ
#include <stdlib.h>
#include <malloc.h>
#undef environ
/* Preserve CRT declarations and adapt Zig's byte/const pointer types. */
static inline uint8_t *zova_generated_getenv(uint8_t const *name) {
    return (uint8_t *)getenv((char const *)name);
}
static inline uintptr_t zova_generated__msize(void const *ptr) {
    return (uintptr_t)_msize((void *)ptr);
}
''')


if __name__ == "__main__":
    path = Path(sys.argv[1])
    path.write_text(fix_source(path.read_text()))
