import os
from pathlib import Path
import unittest
from unittest.mock import patch
from fixture_paths import validate_unix_fixture_paths


class FixturePathsTest(unittest.TestCase):
    def test_socket_boundary_includes_child_directory_and_terminator(self):
        for platform, limit in [('darwin', 104), ('linux', 108)]:
            suffix = len('/0/admin.sock')
            root = Path('/' + 'x' * (limit - 2 - suffix))
            with patch('fixture_paths.sys.platform', platform):
                validate_unix_fixture_paths(root)
                with self.assertRaisesRegex(ValueError, 'shorter --directory'):
                    validate_unix_fixture_paths(Path(str(root) + 'x'))

    def test_multibyte_paths_are_charged_as_socket_address_bytes(self):
        root = Path('/' + 'я' * 44)
        self.assertEqual(len(os.fsencode(root / '0/admin.sock')), 102)
        with patch('fixture_paths.sys.platform', 'darwin'):
            validate_unix_fixture_paths(root)
            with self.assertRaises(ValueError):
                validate_unix_fixture_paths(Path(str(root) + 'я'))


if __name__ == '__main__':
    unittest.main()
