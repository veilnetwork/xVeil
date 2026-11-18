#!/usr/bin/env python3
"""Read-only macOS USB presence for one explicitly selected private serial.

No ADB service, app, interface or setting is changed. Output contains no serial,
USB inventory, paths or raw tool errors. An unsupported/empty probe is unknown,
never evidence that the phone was unplugged.
"""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import sys
from xml.parsers.expat import ExpatError


def profiler_type(text):
    supported = {line.strip() for line in text.splitlines()}
    return next((name for name in ('SPUSBHostDataType', 'SPUSBDataType')
                 if name in supported), None)


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def classify(serial, registry, data_types):
    if not isinstance(serial, str) or not serial.strip() or len(serial) > 512:
        raise ValueError('An explicit target serial is required')
    result = {'profiler_query': profiler_type(data_types),
              'usb_target': 'unknown', 'adb_usb_interface': 'unknown'}
    try:
        tree = plistlib.loads(registry)
    except (ValueError, TypeError, plistlib.InvalidFileException, ExpatError):
        return result
    if not isinstance(tree, list):
        return result
    devices = [row for row in walk(tree)
               if 'idVendor' in row or 'USB Serial Number' in row or 'kUSBSerialNumberString' in row]
    if not devices:
        return result
    targets = [row for row in devices if
               row.get('USB Serial Number') == serial or row.get('kUSBSerialNumberString') == serial]
    result['usb_target'] = 'present' if targets else 'absent'
    if targets:
        adb = any(row.get('bInterfaceClass') == 255 and row.get('bInterfaceSubClass') == 66
                  and row.get('bInterfaceProtocol') == 1
                  for target in targets for row in walk(target))
        result['adb_usb_interface'] = 'present' if adb else 'absent'
    return result


def probe(serial):
    classify(serial, b'', '')
    try:
        types = subprocess.run(['system_profiler', '-listDataTypes'], capture_output=True,
                               timeout=20, text=True)
        registry = subprocess.run(['ioreg', '-p', 'IOService', '-r', '-c', 'IOUSBHostDevice',
                                   '-l', '-a'], capture_output=True, timeout=20)
        return classify(serial, registry.stdout if registry.returncode == 0 else b'',
                        types.stdout if types.returncode == 0 else '')
    except (OSError, subprocess.TimeoutExpired):
        return {'profiler_query': None, 'usb_target': 'unknown', 'adb_usb_interface': 'unknown'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target-snapshot', required=True, type=Path,
                        help='Private JSON containing the intended device serial')
    args = parser.parse_args()
    try:
        serial = json.loads(args.target_snapshot.read_text())['serial']
        # Validate before invoking any external tool; no implicit default target.
        classify(serial, b'', '')
        result = probe(serial)
    except (OSError, ValueError, KeyError, TypeError):
        print('Invalid private USB target snapshot', file=sys.stderr)
        return 2
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    sys.exit(main())
