import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).parents[1] / "check-abi-coverage.py"
SPEC = importlib.util.spec_from_file_location("check_abi_coverage", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

HEADER = """
/* zova_in_comment(void); */
typedef void (*zova_callback)(void *user_data);
// zova_line_comment(void);
uint32_t zova_alpha(void);
const char *zova_beta(zova_status status);
zova_status zova_gamma(
    const zova_gamma_request *request);
"""


class HeaderTests(unittest.TestCase):
    def test_reads_declarations_but_not_comments_or_typedefs(self):
        self.assertEqual(MODULE.header_functions(HEADER), ["zova_alpha", "zova_beta", "zova_gamma"])

    def test_repository_header_declares_functions(self):
        header = (Path(__file__).parents[2] / "include/zova.h").read_text()
        self.assertGreater(len(MODULE.header_functions(header)), 200)


class CheckTests(unittest.TestCase):
    functions = ["zova_alpha", "zova_beta", "zova_gamma"]

    def test_covered_and_allow_listed_functions_pass(self):
        sources = {"rust": "sys::zova_alpha(); sys::zova_beta(); zova_gamma()", "go": "C.zova_alpha(); C.zova_beta()"}
        allowlist = {"go": {"zova_gamma": "covered elsewhere"}}
        self.assertEqual(MODULE.check(self.functions, sources, allowlist), [])

    def test_reports_a_missing_function(self):
        problems = MODULE.check(self.functions, {"go": "C.zova_alpha(); C.zova_beta()"}, {})
        self.assertEqual(problems, ["go: zova_gamma is neither referenced nor allow-listed"])

    def test_a_longer_name_does_not_count_as_a_reference(self):
        problems = MODULE.check(["zova_alpha"], {"go": "C.zova_alpha_many()"}, {})
        self.assertEqual(problems, ["go: zova_alpha is neither referenced nor allow-listed"])

    def test_reports_stale_and_unexplained_allow_list_entries(self):
        sources = {"go": "C.zova_alpha(); C.zova_beta(); C.zova_gamma()"}
        allowlist = {"go": {"zova_alpha": "stale", "zova_removed": "gone", "zova_gamma": " "}, "swift": {}}
        self.assertEqual(MODULE.check(self.functions, sources, allowlist), [
            "scripts/abi-coverage-allowlist.json: unknown binding 'swift'",
            "go: allow-listed zova_alpha is referenced; remove it from scripts/abi-coverage-allowlist.json",
            "go: allow-listed zova_gamma is referenced; remove it from scripts/abi-coverage-allowlist.json",
            "go: allow-listed zova_gamma needs a reason",
            "go: allow-listed zova_removed is not declared in include/zova.h",
        ])

    def test_repository_bindings_are_covered(self):
        self.assertEqual(MODULE.main(["check-abi-coverage.py", str(Path(__file__).parents[2])]), 0)


if __name__ == "__main__":
    unittest.main()
