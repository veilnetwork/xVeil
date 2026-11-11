"""Compile __FILE__ through the actual Unix wrapper command generators."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

MEDIA = Path(__file__).resolve().parents[1] / 'third_party/veil/flutter/veil_media'
CXX = shutil.which('clang++') or shutil.which('c++')


@unittest.skipUnless(CXX, 'A native C++ compiler is required for the binary check')
class SourcePathPrivacyTest(unittest.TestCase):
    def test_wrappers_remap_source_paths_without_losing_the_file_name(self):
        scripts = ['macos/build_veil_media_dylib.sh', 'ios/build_veil_media_ios.sh',
                   'linux/build_veil_media_so_linux.sh', 'android/build_veil_media_so.sh']
        for script in scripts:
            with self.subTest(script=script), tempfile.TemporaryDirectory(
                    dir=os.environ.get('TMPDIR')) as directory:
                root = Path(directory)
                source = root / 'private-operator/src'
                source.mkdir(parents=True)
                probe = source / 'probe.cc'
                probe.write_text('#include <cstdio>\nint main(){std::puts(__FILE__);}\n')
                binary = root / 'probe'
                cc = root / 'compile_commands.json'
                cc.write_text(json.dumps([{
                    'directory': str(root), 'file': 'call/call.cc',
                    'command': f'{CXX} -std=c++17 call/call.cc -o original',
                }]))
                text = (MEDIA / script).read_text()
                match = re.search(r"compile_tu\(\).*?<<'PY'[^\n]*\n(.*?)\nPY", text, re.S)
                self.assertIsNotNone(match, 'Production command generator was renamed')
                command = subprocess.run(
                    [sys.executable, '-', str(cc), str(probe), str(binary),
                     str(source), str(root)], input=match.group(1),
                    capture_output=True, text=True, check=True).stdout
                subprocess.run(['bash', '-c', command], check=True,
                               capture_output=True, text=True)
                ran = subprocess.run([str(binary)], check=True,
                                     capture_output=True, text=True)
                self.assertEqual(ran.stdout.strip(), '/src/veil-media/probe.cc')
                self.assertNotIn(b'private-operator', binary.read_bytes())


if __name__ == '__main__':
    unittest.main()
