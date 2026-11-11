import ctypes
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from strip_macos_debug_info import strip_app, is_macho


class StripMacosDebugInfoTest(unittest.TestCase):
    def test_non_binary_and_java_magic_are_not_macho(self):
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp) / "input"
            for data in [b"text", b"\xca\xfe\xba\xbe\x00\x00\x00\x3d"]:
                file.write_bytes(data)
                self.assertFalse(is_macho(file))

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "needs Apple tools")
    def test_real_library_code_exports_and_external_dsym_survive(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as tmp:
            base = Path(tmp)
            app = base / "fixture.app"
            frameworks = app / "Contents/Frameworks"
            frameworks.mkdir(parents=True)
            source = base / "fixture.c"
            source.write_text("static __attribute__((noinline)) int helper(void) { return 42; }\n"
                              "int fixture_answer(void) { return helper(); }\n")
            env = {**os.environ, "TMPDIR": "/private/tmp/"}
            binary = frameworks / "fixture.dylib"
            object_file = base / "fixture.o"
            subprocess.run(["xcrun", "clang", "-g", "-O0", "-c", str(source),
                            "-o", str(object_file)], capture_output=True, check=True, env=env)
            subprocess.run(["xcrun", "clang", "-dynamiclib", str(object_file),
                            "-o", str(binary)], capture_output=True, check=True, env=env)
            dsym = base / "fixture.dSYM"
            subprocess.run(["xcrun", "dsymutil", str(binary), "-o", str(dsym)],
                           capture_output=True, check=True, env=env)
            dsym_bytes = {f.relative_to(dsym): f.read_bytes() for f in dsym.rglob("*") if f.is_file()}
            before = subprocess.run(["xcrun", "nm", "-ap", str(binary)], capture_output=True, check=True).stdout
            uuid = subprocess.run(["xcrun", "dwarfdump", "--uuid", str(binary)],
                                  capture_output=True, check=True).stdout
            self.assertIn(str(source.parent).encode(), before)
            alias = frameworks / "alias.dylib"
            alias.symlink_to(binary.name)
            self.assertEqual(strip_app(app)["binaries_processed"], 1)
            after = subprocess.run(["xcrun", "nm", "-ap", str(binary)], capture_output=True, check=True).stdout
            self.assertNotIn(str(source.parent).encode(), after)
            self.assertIn(b"_fixture_answer", after)
            self.assertIn(b"_helper", after)
            self.assertEqual(uuid, subprocess.run(["xcrun", "dwarfdump", "--uuid", str(binary)],
                                                 capture_output=True, check=True).stdout)
            self.assertEqual(dsym_bytes, {f.relative_to(dsym): f.read_bytes() for f in dsym.rglob("*") if f.is_file()})
            subprocess.run(["codesign", "--force", "--sign", "-", str(binary)], capture_output=True, check=True)
            library = ctypes.CDLL(str(binary))
            self.assertEqual(library.fixture_answer(), 42)

    def test_external_link_is_refused_before_modifying_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            app = base / "fixture.app"
            app.mkdir()
            sentinel = base / "outside"
            sentinel.write_text("unchanged")
            try:
                (app / "alias").symlink_to(sentinel)
            except OSError:
                self.skipTest("host cannot create symlink fixture")
            with self.assertRaises(ValueError):
                strip_app(app)
            self.assertEqual(sentinel.read_text(), "unchanged")


if __name__ == "__main__":
    unittest.main()
