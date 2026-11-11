"""Portable staging guards; symbol validation itself has a separate native gate."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    'media_provenance', ROOT / 'scripts/verify-media-provenance.py')
media = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media)


class StageMediaTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ['scripts/stage-macos-media.py',
                     'scripts/verify-media-provenance.py',
                     'third_party/veil/flutter/veil_media/source_provenance.py']:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        self.source = self.root / 'third_party/veil/flutter/veil_media/src'
        self.source.mkdir()
        (self.source / 'engine.cc').write_bytes(b'int engine();\n')
        self.binary = self.root / 'build/libveil_media.dylib'
        self.binary.parent.mkdir()
        self.binary.write_bytes(b'current engine fixture')
        self.binary.chmod(0o755)
        media._native.record_build(self.source, self.binary, media.source_digest(self.source))
        self.destination = self.root / 'app/Contents/Frameworks'
        self.destination.mkdir(parents=True)
        self.previous = self.destination / self.binary.name
        self.previous.write_bytes(b'previous bundled engine')
        self.symbol_check = self.root / 'scripts/check-media-symbols.sh'
        self.symbol_check.write_text('exit 0\n')

    def run_stage(self):
        return subprocess.run([sys.executable, str(self.root / 'scripts/stage-macos-media.py'),
                               str(self.binary), str(self.destination)],
                              capture_output=True, text=True)

    def assert_refused(self):
        result = self.run_stage()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.previous.read_bytes(), b'previous bundled engine')
        self.assertEqual(list(self.destination.glob('.media-stage-*')), [])

    def test_current_binary_is_staged(self):
        result = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.previous.read_bytes(), self.binary.read_bytes())
        self.assertEqual(self.previous.stat().st_mode & 0o777, 0o755)
        self.assertEqual(list(self.destination.glob('.media-stage-*')), [])

    def test_absent_optional_engine_removes_an_earlier_copy(self):
        self.binary.unlink()
        self.assertEqual(self.run_stage().returncode, 0)
        self.assertFalse(self.previous.exists())

    def test_missing_provenance_is_not_silently_treated_as_no_media(self):
        self.binary.with_name(self.binary.name + '.provenance').unlink()
        self.assert_refused()

    def test_changed_binary_is_refused_even_with_current_source_record(self):
        self.binary.write_bytes(b'old engine, same ABI')
        self.assert_refused()

    def test_source_change_requires_rebuild(self):
        (self.source / 'engine.cc').write_bytes(b'int fixed_engine();\n')
        self.assert_refused()

    def test_symbol_failure_aborts_instead_of_returning_a_successful_bundle(self):
        self.symbol_check.write_text('exit 7\n')
        self.assert_refused()

    def test_staged_bytes_are_rechecked_after_symbol_validation(self):
        self.symbol_check.write_text('printf changed > "$1"\n')
        self.assert_refused()


if __name__ == '__main__':
    unittest.main()
