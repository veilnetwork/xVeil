"""Exercise CI preparation, including build/load failures, without Rust builds."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(shutil.which('bash') and shutil.which('cc'), 'needs bash and a C compiler')
class NativeTestPreparationTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        script = Path(__file__).with_name('prepare_native_tests.sh')
        (self.root / 'scripts').mkdir()
        self.script = self.root / 'scripts' / script.name
        shutil.copyfile(script, self.script)
        tools = self.root / 'tools'
        tools.mkdir()
        (tools / 'uname').write_text('#!/bin/sh\nprintf "Linux\\n"\n')
        (tools / 'uname').chmod(0o755)
        cargo = tools / 'cargo'
        cargo.write_text('#!' + sys.executable + '\n' + '''
import json, os, pathlib, subprocess, sys
target = pathlib.Path(os.environ['CARGO_TARGET_DIR'])
args = sys.argv[1:]
package = args[args.index('-p') + 1]
with open(os.environ['COMMAND_LOG'], 'a') as out:
    out.write(json.dumps({'target': str(target), 'args': args}) + '\\n')
mode = os.environ.get('PROBE_FAILURE')
if mode == 'build': sys.exit(23)
if mode == 'missing': sys.exit(0)
symbols = {
    'hidden-volume-ffi': ['uniffi_hidden_volume_ffi_fn_constructor_spacehandle_open',
                         'uniffi_hidden_volume_ffi_fn_constructor_spacehandle_create_with_padding'],
    'veilclient-ffi': ['veil_abi_contract_hash', 'veil_config_init'],
}[package]
if mode == 'abi': symbols = ['unrelated_symbol']
output = target / 'release' / ('lib' + package.replace('-', '_') + '.so')
output.parent.mkdir(parents=True, exist_ok=True)
source = output.with_suffix('.c')
source.write_text('\\n'.join('void ' + s + '(void) {}' for s in symbols))
subprocess.run([os.environ['TEST_CC'], '-shared', '-fPIC', str(source), '-o', str(output)], check=True)
''')
        cargo.chmod(0o755)
        self.environment = os.environ | {
            'PATH': str(tools) + os.pathsep + os.environ['PATH'],
            'RUNNER_TEMP': str(self.root),
            'GITHUB_ENV': str(self.root / 'github-env'),
            'COMMAND_LOG': str(self.root / 'commands.jsonl'),
            'TEST_CC': shutil.which('cc'),
        }

    def run_preparation(self, failure=''):
        return subprocess.run(['bash', str(self.script)], env=self.environment | {
            'PROBE_FAILURE': failure,
        }, text=True, capture_output=True)

    def test_builds_both_checkouts_and_exports_loaded_libraries(self):
        result = self.run_preparation()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = [json.loads(row) for row in (self.root / 'commands.jsonl').read_text().splitlines()]
        self.assertEqual(len(commands), 2)
        self.assertNotEqual(commands[0]['target'], commands[1]['target'])
        for command, package in zip(commands, ['hidden-volume-ffi', 'veilclient-ffi']):
            args = command['args']
            self.assertEqual(args[:3], ['build', '--release', '--locked'])
            self.assertEqual(args[args.index('-p') + 1], package)
        features = commands[1]['args'][-1].split(',')
        self.assertIn('node-embedded', features)
        self.assertIn('packet-tunnel', features)
        self.assertIn('allow-empty-seeds', features)
        exports = dict(row.split('=', 1) for row in (self.root / 'github-env').read_text().splitlines())
        self.assertEqual(set(exports), {'XVEIL_HV_DYLIB', 'VEIL_FFI_DYLIB'})
        self.assertTrue(all(Path(p).is_absolute() and Path(p).is_file() for p in exports.values()))
        self.assertEqual(result.stdout.count('load/entrypoints OK; sha256='), 2)

    def test_failed_build_or_unloadable_contract_never_exports_success(self):
        for failure in ['build', 'missing', 'abi']:
            with self.subTest(failure=failure):
                result = self.run_preparation(failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / 'github-env').exists())


if __name__ == '__main__':
    unittest.main()
