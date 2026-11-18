import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from probe_android_usb import classify, probe, profiler_type

SERIAL = 'FAKE_PRIVATE_SERIAL_CANARY'
ADB = {'bInterfaceClass': 255, 'bInterfaceSubClass': 66, 'bInterfaceProtocol': 1}


def registry(serial=SERIAL, interface=True):
    return plistlib.dumps([{'USB Serial Number': serial, 'idVendor': 1,
                           'IORegistryEntryChildren': [ADB] if interface else []}])


class UsbProbeTests(unittest.TestCase):
    def test_supported_profiler_type_is_discovered_instead_of_assumed(self):
        self.assertEqual(profiler_type('Data Types:\n SPUSBHostDataType\n'), 'SPUSBHostDataType')
        self.assertEqual(profiler_type(' SPUSBDataType\n'), 'SPUSBDataType')
        self.assertIsNone(profiler_type(' SPStorageDataType\n'))

    def test_target_and_adb_interface_use_exact_serial_not_model_substring(self):
        result = classify(SERIAL, registry(), 'SPUSBHostDataType')
        self.assertEqual(result['usb_target'], 'present')
        self.assertEqual(result['adb_usb_interface'], 'present')
        self.assertNotIn(SERIAL, json.dumps(result))
        self.assertEqual(classify('OTHER_FAKE_TARGET', registry(), '')['usb_target'], 'absent')

    def test_adb_disabled_and_duplicate_subtrees_are_handled(self):
        self.assertEqual(classify(SERIAL, registry(interface=False), '')['adb_usb_interface'], 'absent')
        tree = plistlib.loads(registry())
        self.assertEqual(classify(SERIAL, plistlib.dumps(tree+tree), '')['usb_target'], 'present')

    def test_unsupported_empty_and_corrupt_enumeration_never_mean_absent(self):
        for data in (b'', b'not a plist', b'<?xml version="1.0"?><plist><dict>',
                     plistlib.dumps([]), plistlib.dumps({})):
            with self.subTest(data=data):
                r = classify(SERIAL, data, '')
                self.assertEqual(r['usb_target'], 'unknown')
                self.assertEqual(r['adb_usb_interface'], 'unknown')
        # Missing old profiler support does not erase real IORegistry evidence.
        self.assertEqual(classify(SERIAL, registry(), '')['usb_target'], 'present')

    def test_missing_explicit_target_is_rejected(self):
        for serial in (None, '', ' ', 12, 'x'*513):
            with self.subTest(serial=serial), self.assertRaises(ValueError): classify(serial, b'', '')

    def test_tool_failure_is_unknown_and_raw_error_is_not_returned(self):
        with patch('probe_android_usb.subprocess.run', side_effect=OSError('RAW_PRIVATE_ERROR_CANARY')):
            result = probe(SERIAL)
            self.assertEqual(result['usb_target'], 'unknown')
            self.assertNotIn('RAW_PRIVATE', json.dumps(result))

    def test_cli_invalid_private_path_does_not_leak_filename_or_json(self):
        script = Path(__file__).with_name('probe_android_usb.py')
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder)/'PRIVATE_PATH_CANARY.json'
            p.write_text('{invalid RAW_PRIVATE_JSON_CANARY}')
            result = subprocess.run([sys.executable, str(script), '--target-snapshot', str(p)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, '')
            self.assertEqual(result.stderr.strip(), 'Invalid private USB target snapshot')


if __name__ == '__main__': unittest.main()
