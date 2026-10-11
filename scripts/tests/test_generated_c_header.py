import importlib.util
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "generated_c_header", Path(__file__).parents[1] / "fix-generated-c-header.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
GCC = shutil.which("gcc-15") or shutil.which("gcc")


class GeneratedCHeaderTests(unittest.TestCase):
    def test_preserves_clang_and_unknown_compiler_branches(self):
        header = '''#if zig_has_attribute(not_tail_called)
#define zig_never_tail __attribute__((not_tail_called)) zig_never_inline
#else
#define zig_never_tail zig_never_tail_unavailable
#endif
'''
        result = MODULE.fix_header(header)
        self.assertIn("#elif defined(zig_gcc)", result)
        self.assertIn('optimize("no-optimize-sibling-calls")', result)
        self.assertIn("not_tail_called", result)
        self.assertIn("#else\n#define zig_never_tail zig_never_tail_unavailable", result)

    def test_fails_closed_when_zig_header_changes(self):
        with self.assertRaises(ValueError):
            MODULE.fix_header("/* changed Zig header */")

    @unittest.skipUnless(GCC and shutil.which("zig"), "requires GCC and Zig")
    def test_never_tail_wrapper_compiles_and_retains_real_call(self):
        version = subprocess.check_output([GCC, "--version"], text=True)
        if "clang" in version.lower():
            self.skipTest("requires GNU GCC, not the clang gcc alias")
        env = subprocess.check_output(["zig", "env"], text=True)
        lib_dir = re.search(r'\.lib_dir\s*=\s*"([^"]+)"', env).group(1)
        header = (Path(lib_dir) / "zig.h").read_text()
        source = '''#define ZIG_TARGET_MAX_INT_ALIGNMENT 16
#include "zig.h"
extern void *lookup(void *, const char *);
zig_never_tail void *wrapper(void *handle, const char *name) {
    return lookup(handle, name);
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "zig.h").write_text(MODULE.fix_header(header))
            command = [GCC, "-std=c11", "-O2", "-Werror", "-S", "-x", "c",
                       "-I", directory, "-o", "-", "-"]
            result = subprocess.run(command, input=source, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            # Both maintained Linux architectures must call, not tail-branch,
            # so lookup sees an address within the generated host library.
            self.assertRegex(result.stdout, r"\b(?:call\w*|bl)\s+_?lookup\b")
            self.assertNotRegex(result.stdout, r"\b(?:jmp\w*|b)\s+_?lookup\b")


if __name__ == "__main__":
    unittest.main()
