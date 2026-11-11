import importlib.util
import hashlib
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    'media_provenance', Path(__file__).with_name('verify-media-provenance.py'))
media = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media)


class MediaProvenanceTest(unittest.TestCase):
    def test_binary_digest_is_required_and_checked_for_local_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'src'
            source.mkdir()
            (source / 'engine.cc').write_bytes(b'int start();\n')
            binary = Path(directory) / 'engine.dylib'
            binary.write_bytes(b'current fixture binary')
            provenance = binary.with_name(binary.name + '.provenance')
            row = 'media-source-sha256: ' + media.source_digest(source) + '\n'
            sha = 'sha256: ' + hashlib.sha256(binary.read_bytes()).hexdigest() + '\n'
            for text in [row, row + 'sha256: bad\n', row + sha + sha]:
                provenance.write_text(text)
                with self.assertRaisesRegex(ValueError, 'binary sha256'):
                    media.verify(source, provenance, binary)
            provenance.write_text(row + sha)
            media.verify(source, provenance, binary)
            binary.write_bytes(b'an older engine with the same symbols')
            with self.assertRaisesRegex(ValueError, 'binary differs'):
                media.verify(source, provenance, binary)

    def test_builder_refuses_source_changes_without_overwriting_its_record(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'src'
            source.mkdir()
            implementation = source / 'engine.cc'
            implementation.write_bytes(b'int start();\n')
            before = media.source_digest(source)
            binary = Path(directory) / 'engine.dylib'
            binary.write_bytes(b'fixture binary')
            media._native.record_build(source, binary, before)
            record = binary.with_name(binary.name + '.provenance')
            original = record.read_bytes()
            media.verify(source, record, binary)
            implementation.write_bytes(b'int start_changed();\n')
            with self.assertRaisesRegex(ValueError, 'source changed'):
                media._native.record_build(source, binary, before)
            self.assertEqual(record.read_bytes(), original)
            self.assertEqual(list(Path(directory).glob('.media-provenance-*')), [])

    def test_path_ordering_is_independent_of_host_platform(self):
        # pathlib orders Windows paths case-insensitively. Reproduce that
        # ordering on this host rather than waiting for a Windows publisher.
        class WindowsOrderedPath(type(Path())):
            def __lt__(self, other):
                return str(self).casefold() < str(other).casefold()

        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            (source / 'Z.cc').write_bytes(b'int start();\n')
            (source / 'a.h').write_bytes(b'int stop();\n')
            windows_source = WindowsOrderedPath(directory)
            self.assertIsInstance(next(windows_source.rglob('*')), WindowsOrderedPath)
            self.assertEqual(media.source_digest(source), media.source_digest(windows_source))

    def test_unchanged_abi_does_not_accept_old_implementation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'src'
            source.mkdir()
            implementation = source / 'engine.cc'
            implementation.write_text('int set_mic_muted() { return 0; }\n')
            provenance = root / 'engine.provenance'
            provenance.write_text('media-source-sha256: ' + media.source_digest(source) + '\r\n')
            media.verify(source, provenance)
            implementation.write_bytes(b'int set_mic_muted() { return 0; }\r\n')
            media.verify(source, provenance)
            implementation.write_text('int set_mic_muted() { return start_capture(); }\n')
            with self.assertRaisesRegex(ValueError, 'rebuild and repin'):
                media.verify(source, provenance)

    def test_missing_duplicate_and_malformed_digest_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'src'
            source.mkdir()
            (source / 'engine.h').write_bytes(b'int start();\n')
            row = 'media-source-sha256: ' + media.source_digest(source) + '\n'
            provenance = root / 'engine.provenance'
            for text in ['sha256: ' + '0' * 64, row + row, 'media-source-sha256: invalid']:
                provenance.write_text(text)
                with self.assertRaises(ValueError):
                    media.verify(source, provenance)

    def test_digest_binds_file_names_and_rejects_empty_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            with self.assertRaises(ValueError):
                media.source_digest(source)
            first = source / 'first.h'
            first.write_bytes(b'same bytes')
            digest = media.source_digest(source)
            first.rename(source / 'second.h')
            self.assertNotEqual(digest, media.source_digest(source))


if __name__ == '__main__':
    unittest.main()
