"""Check the objdump formats used for x64 and ARM64 PE export tables."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == "posix", "The symbol checker is a POSIX shell script")
class PeExportFormatTest(unittest.TestCase):
    def check(self, output, *, llvm=False):
        with tempfile.TemporaryDirectory(prefix="xveil-pe-exports-") as temporary:
            folder = Path(temporary)
            fixture = folder / "objdump.txt"
            fixture.write_text(output)
            for name in ("x86_64-w64-mingw32-objdump", "llvm-objdump"):
                command = "exit 1" if llvm and name.startswith("x86_64") else (
                    "cat " + shlex.quote(str(fixture)))
                tool = folder / name
                tool.write_text("#!/bin/sh\n" + command + "\n")
                tool.chmod(0o700)
            library = folder / "engine.dll"
            library.write_bytes(b"fixture: the reader output is supplied above")
            return subprocess.run(["bash", str(ROOT / "scripts/check-media-symbols.sh"), str(library)],
                                  cwd=ROOT, text=True, capture_output=True,
                                  env={**os.environ, "PATH": str(folder) + os.pathsep + os.environ["PATH"]})

    def test_gnu_name_pointer_table(self):
        result = self.check('Imports: veil_media_not_an_export\n'
                            '[Ordinal/Name Pointer] Table\n'
                            '  [  0] veil_media_fixture_api\n\n')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('PE: exported 1 ', result.stdout)

    def test_llvm_arm64_export_table(self):
        # llvm-objdump can read ARM64 PE when x64 binutils cannot; it uses a
        # different table header. Imports/ordinary symbols are not exports.
        result = self.check('Imports: veil_media_not_an_export\n'
                            'Export Table:\n DLL name: engine.dll\n Ordinal base: 1\n'
                            ' Ordinal      RVA  Name\n'
                            '       1  0x4059c  veil_media_fixture_api\n\n'
                            'Import Table:\n       1  0x12345  veil_media_not_an_export\n', llvm=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('PE: exported 1 ', result.stdout)

    def test_import_names_alone_never_pass_as_exports(self):
        result = self.check('Import Table:\n       1  0x12345  veil_media_fixture_api\n', llvm=True)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('exports no veil_media_', result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
