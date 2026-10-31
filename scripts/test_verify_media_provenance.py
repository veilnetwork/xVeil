import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    'media_provenance', Path(__file__).with_name('verify-media-provenance.py'))
media = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media)


class MediaProvenanceTest(unittest.TestCase):
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
