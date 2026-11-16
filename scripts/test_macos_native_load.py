"""Ask the Darwin loader about real bundle libraries before publication."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from aot_build import artifact_directory, check_artifact, _publish_directory
from check_hidden_volume_abi import CONTRACT_SYMBOL, read_contract


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
        for name in ("libveilclient_ffi.dylib",):
            subprocess.run(["xcrun", "clang", "-dynamiclib", str(source),
                            "-o", str(self.frameworks / name)], check=True, capture_output=True)
        self.storage_fixture()

    def storage_fixture(self, *, omit=None, bad_checksum=False, bad_contract=False):
        contract = read_contract()
        lines = ['#include <stdint.h>']
        padding = 'uniffi_hidden_volume_ffi_checksum_constructor_spacehandle_create_with_padding'
        for name in sorted(contract.symbols):
            if name == omit:
                continue
            if name == CONTRACT_SYMBOL:
                lines.append(f'uint32_t {name}(void) {{ return {contract.version + int(bad_contract)}; }}')
            elif name in contract.checksums:
                value = contract.checksums[name] + int(bad_checksum and name == padding)
                lines.append(f'uint16_t {name}(void) {{ return {value}; }}')
            else:
                # Export-presence fixture, never invoked as a storage operation.
                lines.append(f'void {name}(void) {{}}')
        source = self.source / 'storage-fixture.c'
        source.write_text('\n'.join(lines))
        subprocess.run(['xcrun', 'clang', '-dynamiclib', str(source), '-o',
                        str(self.frameworks / 'libhidden_volume_ffi.dylib')],
                       check=True, capture_output=True)

    def test_loadable_storage_without_current_ffi_contract_is_refused(self):
        self.storage_fixture(omit='uniffi_hidden_volume_ffi_checksum_constructor_spacehandle_create_with_padding')
        with self.assertRaises(subprocess.CalledProcessError):
            check_artifact(self.source, "macos")

    def test_loadable_matching_storage_contract_passes(self):
        check_artifact(self.source, "macos")

    def test_wrong_method_checksum_is_refused(self):
        self.storage_fixture(bad_checksum=True)
        with self.assertRaises(subprocess.CalledProcessError):
            check_artifact(self.source, 'macos')

    def test_wrong_contract_version_is_refused(self):
        self.storage_fixture(bad_contract=True)
        with self.assertRaises(subprocess.CalledProcessError):
            check_artifact(self.source, 'macos')

    def test_missing_bound_function_is_refused_even_with_its_checksum(self):
        self.storage_fixture(omit='uniffi_hidden_volume_ffi_fn_constructor_spacehandle_create_with_padding')
        with self.assertRaises(subprocess.CalledProcessError):
            check_artifact(self.source, 'macos')

    def test_abi_mismatch_does_not_replace_previous_artifact(self):
        self.storage_fixture(bad_checksum=True)
        previous = self.source / 'previous-abi.app'
        previous.mkdir()
        (previous / 'preserved').write_bytes(b'previous artifact')
        with self.assertRaises(subprocess.CalledProcessError):
            _publish_directory(self.app, previous, target='macos')
        self.assertEqual((previous / 'preserved').read_bytes(), b'previous artifact')
        self.assertFalse(list(previous.parent.glob('.xveil-aot-publish-*')))

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
