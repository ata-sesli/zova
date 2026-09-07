import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "windows_c", Path(__file__).parents[1] / "fix-windows-generated-c.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class WindowsGeneratedCTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("clang"), "requires clang")
    def test_compiles_with_crt_macros_and_prototypes(self):
        source = '''#include "zig.h"
struct generated { int environ; };
zig_extern uint8_t *getenv(uint8_t const *a0);
zig_extern uintptr_t _msize(void const *a0);
void test(void) { (void)getenv(0); (void)_msize(0); }
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "zig.h").write_text('''#include <stdint.h>
#include <stdlib.h>
#include <malloc.h>
#define zig_extern extern
#define environ (*__p__environ())
''')
            (root / "malloc.h").write_text('''#pragma once
#include <stddef.h>
size_t _msize(void *);
''')
            command = ["clang", "-x", "c", "-fsyntax-only", "-I", directory, "-"]
            before = subprocess.run(command, input=source, text=True, capture_output=True)
            self.assertNotEqual(before.returncode, 0)
            self.assertIn("conflicting types", before.stderr)
            after = subprocess.run(
                command, input=MODULE.fix_source(source), text=True, capture_output=True
            )
            self.assertEqual(after.returncode, 0, after.stderr)

    def test_adapts_declarations_and_calls(self):
        source = '''#include "zig.h"
zig_extern uint8_t *getenv(uint8_t const *a0);
zig_extern uintptr_t _msize(void const *a0);
void test(void) { getenv(0); _msize(0); }
'''
        result = MODULE.fix_source(source)
        self.assertIn("zova_generated_getenv(0); zova_generated__msize(0);", result)
        self.assertNotIn("zig_extern", result)
        self.assertIn("#undef environ", result)
        self.assertIn("getenv((char const *)name)", result)
        self.assertIn("_msize((void *)ptr)", result)

    def test_fails_closed_when_generator_declarations_change(self):
        with self.assertRaises(ValueError):
            MODULE.fix_source('#include "zig.h"\n')


if __name__ == "__main__":
    unittest.main()
