"""The publication gate must detect private data without publishing it."""
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).with_name('scan-artifacts.py')
SPEC = importlib.util.spec_from_file_location('artifact_scan', SCRIPT)
SCAN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCAN)
CANARY = 'PRIVATE_CANARY'


class ArtifactScanTest(unittest.TestCase):
    def invoke(self, directory, patterns=CANARY):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(directory)],
            env={**os.environ, 'PATTERNS': patterns},
            capture_output=True, text=True,
        )
        self.assertNotIn(CANARY, result.stdout + result.stderr)
        self.assertNotIn(str(directory), result.stdout + result.stderr)
        return result

    def test_ascii_and_utf16_payloads_are_detected_without_context(self):
        for encoding in ['ascii', 'utf-16-le', 'utf-16-be']:
            with self.subTest(encoding=encoding), tempfile.TemporaryDirectory() as d:
                Path(d, 'payload.bin').write_bytes(
                    ('/Users/' + CANARY + '/private').encode(encoding))
                result = self.invoke(d)
                self.assertEqual(result.returncode, 1)
                self.assertIn('forbidden data in entry 1', result.stdout)

    def test_archive_member_names_and_payloads_do_not_escape_to_logs(self):
        for kind in ['zip', 'tar']:
            for in_name in [False, True]:
                with self.subTest(kind=kind, in_name=in_name), tempfile.TemporaryDirectory() as d:
                    name = CANARY + '/payload.bin' if in_name else 'payload.bin'
                    data = b'clean payload' if in_name else CANARY.encode()
                    if kind == 'zip':
                        with zipfile.ZipFile(Path(d, 'bundle.zip'), 'w') as z:
                            z.writestr(name, data)
                    else:
                        with tarfile.open(Path(d, 'bundle.tar.gz'), 'w:gz') as t:
                            member = tarfile.TarInfo(name)
                            member.size = len(data)
                            t.addfile(member, io.BytesIO(data))
                    self.assertEqual(self.invoke(d).returncode, 1)

    def test_tar_link_targets_are_scanned_without_following_them(self):
        with tempfile.TemporaryDirectory() as d:
            with tarfile.open(Path(d, 'bundle.tar.gz'), 'w:gz') as t:
                link = tarfile.TarInfo('link')
                link.type = tarfile.SYMTYPE
                link.linkname = '/Users/' + CANARY + '/missing'
                t.addfile(link)
            self.assertEqual(self.invoke(d).returncode, 1)

    def test_raw_artifact_names_are_also_private(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, CANARY + '.bin').write_bytes(b'clean payload')
            self.assertEqual(self.invoke(d).returncode, 1)

    def test_missing_patterns_and_empty_inputs_fail_closed(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(self.invoke(d).returncode, 1)
            Path(d, 'clean.bin').write_bytes(b'clean payload')
            self.assertEqual(self.invoke(d, '').returncode, 1)
            self.assertEqual(self.invoke(d, 're:ignored\nallow:only').returncode, 1)

    def test_corrupt_archive_is_not_treated_as_a_clean_binary(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, CANARY + '.zip').write_bytes(b'not a zip archive')
            result = self.invoke(d)
            self.assertEqual(result.returncode, 1)
            self.assertIn('artifact scan failed', result.stdout)

    def test_clean_data_and_existing_boundary_allow_rules_still_work(self):
        self.assertEqual(SCAN.hits(b'xlonghandley', ['longhandle'], []), [])
        self.assertTrue(SCAN.hits(b'/Users/longhandle/file', ['longhandle'], []))
        self.assertEqual(SCAN.hits(b'/fixture/longhandle', ['longhandle'], ['/fixture/']), [])
        with tempfile.TemporaryDirectory() as d:
            Path(d, 'clean.bin').write_bytes(b'ordinary safe data')
            self.assertEqual(self.invoke(d).returncode, 0)


if __name__ == '__main__':
    unittest.main()
