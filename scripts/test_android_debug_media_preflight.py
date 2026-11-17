#!/usr/bin/env python3
"""Android debug builds need the same mandatory startup engine as releases."""
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import builder

spec = importlib.util.spec_from_file_location(
    'android_preflight_provenance', Path(builder.__file__).parent /
    'third_party/veil/flutter/veil_media/source_provenance.py')
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)


class AndroidMediaPreflightTest(unittest.TestCase):
    def before_build(self, release, staged):
        with tempfile.TemporaryDirectory(prefix='xveil-android-media-') as directory:
            root = Path(directory)
            (root / 'pubspec.yaml').write_text('version: 1.2.3+4\n')
            source = root / 'third_party/veil/flutter/veil_media/src'
            source.mkdir(parents=True)
            (source / 'engine.cc').write_text('int capture();\n')
            for abi in staged:
                path = root / builder._MEDIA_STAGE_DIR / abi / builder._MEDIA_SO
                path.parent.mkdir(parents=True, exist_ok=True)
                # Admission records are real; ELF/ABI/export checks remain separate.
                path.write_bytes(b'fixture for staging admission')
                provenance.record_build(source, path, provenance.source_digest(source))
            with patch.object(builder, 'ROOT', directory), \
                 contextlib.redirect_stdout(io.StringIO()):
                for step in builder._android(release):
                    if step.argv:
                        return
                    if step.call is not None:
                        step.call()
                self.fail('Android plan has no build command')

    def test_missing_engine_refuses_before_compilation_in_both_modes(self):
        for release in (False, True):
            with self.subTest(release=release):
                with self.assertRaisesRegex(RuntimeError, 'MISSING libveil_media.so'):
                    self.before_build(release, ())

    def test_missing_one_shipped_abi_also_refuses_debug(self):
        for missing in builder._MEDIA_ABIS:
            with self.subTest(missing=missing):
                staged = [abi for abi in builder._MEDIA_ABIS if abi != missing]
                with self.assertRaisesRegex(RuntimeError, missing):
                    self.before_build(False, staged)

    def test_present_engines_allow_reaching_compilation(self):
        for release in (False, True):
            with self.subTest(release=release):
                self.before_build(release, builder._MEDIA_ABIS)


if __name__ == '__main__':
    unittest.main()
