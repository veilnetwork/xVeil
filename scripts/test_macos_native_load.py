"""Ask the Darwin loader about real bundle libraries before publication."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from aot_build import artifact_directory, check_artifact, _publish_directory


@unittest.skipUnless(sys.platform == "darwin", "Requires the Darwin loader")
class MacosNativeLoadTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xveil-native-load-", dir="/private/tmp")
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name)
        self.app = self.source / artifact_directory("macos")
        self.frameworks = self.app / "Contents/Frameworks"
        self.frameworks.mkdir(parents=True)
        source = self.source / "fixture.c"
        source.write_text('int veil_load_fixture(void) { return 42; }\n')
        for name in ("libveilclient_ffi.dylib", "libhidden_volume_ffi.dylib"):
            subprocess.run(["xcrun", "clang", "-dynamiclib", str(source),
                            "-o", str(self.frameworks / name)], check=True, capture_output=True)

    def test_real_libraries_pass(self):
        check_artifact(self.source, "macos")

    def test_unloadable_library_fails_even_when_source_path_scan_is_clean(self):
        (self.frameworks / "libveilclient_ffi.dylib").write_bytes(b"not a loadable native library")
        with self.assertRaises(subprocess.CalledProcessError):
            check_artifact(self.source, "macos")

    def test_copied_library_is_checked_before_replacing_previous_artifact(self):
        previous = self.source / "previous.app"
        previous.mkdir()
        (previous / "preserved").write_bytes(b"previous artifact")
        (self.frameworks / "libhidden_volume_ffi.dylib").write_bytes(b"invalid native library")
        with self.assertRaises(subprocess.CalledProcessError):
            _publish_directory(self.app, previous, target="macos")
        self.assertEqual((previous / "preserved").read_bytes(), b"previous artifact")
        self.assertFalse(list(previous.parent.glob(".xveil-aot-publish-*")))


if __name__ == "__main__":
    unittest.main()
