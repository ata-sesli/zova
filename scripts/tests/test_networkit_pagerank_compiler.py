"""The generated-C PageRank host needs compiler builtins with MSVC's linker."""
import importlib.util
import os
from pathlib import Path
import platform
import shutil
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "networkit_pagerank", Path(__file__).parents[1] / "check-networkit-pagerank.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ConfigureCollected(Exception):
    pass


class NetworKitCompilerTests(unittest.TestCase):
    def configure_commands(self, system, directory):
        commands = []

        def collect(args, *unused, **kwargs):
            command = list(map(str, args))
            commands.append(command)
            if command[:2] == ["cmake", "-S"]:
                raise ConfigureCollected

        with patch.object(MODULE.platform, "system", return_value=system), \
                patch.object(MODULE, "run", side_effect=collect), \
                patch.object(MODULE.subprocess, "check_output", return_value='.{ .lib_dir = "C:\\\\Zig\\\\lib", }'), \
                patch.object(MODULE.sys, "argv", ["check", str(Path(directory) / "run"),
                                                "--packages", str(Path(directory) / "packages")]):
            with self.assertRaises(ConfigureCollected):
                MODULE.main()
        return commands

    def test_windows_supplies_runtime_without_replacing_generated_objects(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = self.configure_commands("Windows", directory)
            runtime = next((c for c in commands if c[:2] == ["zig", "build-lib"]), None)
            self.assertIsNotNone(runtime, "MSVC cannot supply __floattidf and __divti3")
            self.assertEqual(runtime[runtime.index("-target") + 1], "x86_64-windows-msvc")
            self.assertTrue(runtime[2].endswith("compiler_rt.zig"))
            self.assertIn("-fno-builtin", runtime, "runtime memcpy must not call itself")
            self.assertIn("C:\\Zig\\lib", runtime[2])
            root = Path(directory).resolve()
            library = str(root / "run" / "compiler_rt.lib")
            self.assertIn(f"-femit-bin={library}", runtime)
            self.assertIn(f"-DZOVA_COMPILER_RT_LIBRARY={library}", commands[-1])
            archive = next(c for c in commands if c[:2] == ["zig", "ar"])
            self.assertEqual(archive[-2:], [str(root / "packages/zova.o"),
                                           str(root / "packages/sqlite.o")])

    def test_linux_does_not_add_a_windows_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = self.configure_commands("Linux", directory)
            self.assertFalse(any(c[:2] == ["zig", "build-lib"] for c in commands))
            self.assertFalse(any(a.startswith("-DZOVA_COMPILER_RT_LIBRARY=") for a in commands[-1]))

    @unittest.skipUnless(shutil.which("zig"), "requires Zig")
    def test_actual_windows_builtins_link_without_automatic_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = os.environ.copy()
            runtime = MODULE.build_windows_compiler_runtime(root, env)
            obj = root / "probe.obj"
            result = root / "probe.exe"
            MODULE.run(["zig", "cc", "-target", "x86_64-windows-msvc", "-O2",
                        "-fno-sanitize=all", "-fno-stack-protector", "-c",
                        MODULE.ROOT / "tests/compiler_runtime_probe.c", "-o", obj], env)
            if platform.system() == "Windows":
                # Exercise the actual system linker that failed in CI, not a
                # compiler driver that silently supplies the missing runtime.
                command = ["link", "/nologo", "/nodefaultlib", "/opt:ref",
                           "/entry:runtime_probe", "/subsystem:console",
                           f"/out:{result}", obj, runtime]
            else:
                command = ["zig", "build-exe", obj, runtime, "-target",
                           "x86_64-windows-msvc", "-O", "ReleaseFast",
                           "-fno-compiler-rt", "-fentry=runtime_probe", "--subsystem",
                           "console", f"-femit-bin={result}"]
            MODULE.run(command, env)
            self.assertTrue(result.is_file())


if __name__ == "__main__":
    unittest.main()
