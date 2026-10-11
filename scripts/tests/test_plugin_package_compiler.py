"""The plugin smoke host must use the ABI of its generated-C bundle."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "plugin_packages", Path(__file__).parents[1] / "check-plugin-packages.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CompilationCollected(Exception):
    pass


class PluginPackageCompilerTests(unittest.TestCase):
    def compiler_commands(self, system, directory):
        commands = []

        def collect(args, **kwargs):
            commands.append(list(map(str, args)))
            if len(commands) == 5:
                raise CompilationCollected

        # Stop at the process boundary before fixtures or consumers execute;
        # retain the runner's real argument parsing and compiler selection.
        with patch.object(MODULE, "SYSTEM", system), \
                patch.object(MODULE, "run", side_effect=collect), \
                patch.object(MODULE.sys, "argv", ["check", str(Path(directory) / "run"), "--prepare-only"]):
            with self.assertRaises(CompilationCollected):
                MODULE.main()
        return commands[2:]

    def test_windows_compiles_and_links_with_msvc_abi(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = self.compiler_commands("Windows", directory)
            for command in commands:
                self.assertEqual(command[:4], ["zig", "cc", "-target", "x86_64-windows-msvc"])
            if shutil.which("zig"):
                source = '''#ifndef _MSC_VER
#error expected Microsoft C ABI
#endif
_Static_assert(sizeof(long double) == 8, "abi mismatch");
_Static_assert(_Alignof(long double) == 8, "abi mismatch");
'''
                result = subprocess.run(
                    [*commands[0][:4], "-std=c11", "-x", "c", "-c", "-o",
                     str(Path(directory) / "probe.obj"), "-"],
                    input=source, text=True, capture_output=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_non_windows_retains_native_compiler_selection(self):
        for system in ("Linux", "Darwin"):
            with self.subTest(system=system), tempfile.TemporaryDirectory() as directory:
                commands = self.compiler_commands(system, directory)
                for command in commands:
                    self.assertEqual(command[:2], ["zig", "cc"])
                    self.assertNotIn("-target", command)

    def consumer_commands(self, system, directory):
        commands = []
        environments = []

        def collect(args, **kwargs):
            command = list(map(str, args))
            commands.append(command)
            environments.append(kwargs.get("env", {}))
            if command[:2] == ["go", "test"]:
                raise CompilationCollected

        with patch.object(MODULE, "SYSTEM", system), \
                patch.object(MODULE, "run", side_effect=collect):
            with self.assertRaises(CompilationCollected):
                MODULE.check_consumers(Path(directory), {}, [(Path("bundle"), Path("trust"))])
        return commands, environments[-1]

    def test_windows_go_uses_a_gnu_bundle_and_links_ntdll(self):
        with tempfile.TemporaryDirectory() as directory:
            commands, go_env = self.consumer_commands("Windows", directory)
            self.assertEqual(commands[0][:2], ["sh", "scripts/update-generated-c.sh"])
            self.assertEqual(commands[0][-1], "x86_64-pc-windows-gnu")
            compiles = [c for c in commands if c[:2] == ["zig", "cc"]]
            self.assertEqual(len(compiles), 2)
            for command in compiles:
                self.assertEqual(command[2:4], ["-target", "x86_64-windows-gnu"])
            archive = next(c for c in commands if c[:2] == ["zig", "ar"])
            self.assertTrue(all("go-generated" in p for p in archive[-2:]))
            self.assertIn("-lntdll", go_env["CGO_LDFLAGS"].split())

    def test_non_windows_go_reuses_the_checked_generated_objects(self):
        for system in ("Linux", "Darwin"):
            with self.subTest(system=system), tempfile.TemporaryDirectory() as directory:
                commands, go_env = self.consumer_commands(system, directory)
                self.assertEqual(commands[0][:2], ["zig", "ar"])
                self.assertEqual(commands[0][-2:], [str(Path(directory) / "zova.o"), str(Path(directory) / "sqlite.o")])
                self.assertNotIn("-lntdll", go_env["CGO_LDFLAGS"])


if __name__ == "__main__":
    unittest.main()
