"""Check compiler path remapping, including clang-cl's different flag syntax."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import builder


def windows_native_env():
    return next(step.env for step in builder._windows(release=True)
                if step.title == 'veil client FFI')


class BuilderPathRemapTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which('clang'), 'Requires the real assembly compiler')
    def test_windows_arm64_assembly_accepts_flags_and_remaps_file(self):
        # ring uses GNU-driver clang for ARM64 assembly even when CC is
        # clang-cl. Both drivers consume the same CFLAGS from cc-rs.
        with tempfile.TemporaryDirectory(prefix='xveil asm remap ', dir=Path.home()) as directory:
            source = Path(directory) / 'probe.S'
            source.write_text('.text\n.globl remap_probe\nremap_probe:\n ret\n'
                              '.section .rdata,"dr"\n.asciz __FILE__\n')
            output = Path(directory) / 'probe.obj'
            with mock.patch.dict(os.environ, {'CFLAGS': '', 'CXXFLAGS': ''}):
                additions = windows_native_env()
            subprocess.run([shutil.which('clang'), '--target=aarch64-pc-windows-msvc',
                            '-c', str(source), '-o', str(output),
                            *shlex.split(additions['CFLAGS'])],
                           cwd=directory, env={**os.environ, **additions},
                           capture_output=True, check=True)
            raw = output.read_bytes()
            self.assertEqual(int.from_bytes(raw[:2], 'little'), 0xaa64)
            self.assertIn(b'/build/', raw.replace(b'\\', b'/'))
            for prefix in (str(Path.home()), str(Path.home()).replace('\\', '/')):
                self.assertNotIn(prefix.encode(), raw)

    def test_cross_platform_flags_and_caller_options_are_preserved(self):
        with mock.patch.dict(os.environ, {'CXXFLAGS': '-DKEEP_ME=1'}, clear=True):
            generic = builder._build_env()
            self.assertIn('-DKEEP_ME=1', shlex.split(generic['CXXFLAGS']))
            self.assertTrue(any(flag.startswith('-ffile-prefix-map=')
                                for flag in shlex.split(generic['CXXFLAGS'])))
            self.assertFalse(any(key.startswith('CC_') for key in generic))
        with mock.patch('builder.os.path.expanduser', return_value=r'C:\Users\build operator'):
            native = builder._build_env(msvc=True)
            for kind in ('macro', 'debug'):
                self.assertIn(f'-f{kind}-prefix-map=C:/Users/build operator=/build',
                              shlex.split(native['CXXFLAGS']))

    def test_windows_native_steps_use_the_msvc_clang_driver(self):
        # The repo-wide clang/clang++ defaults are GNU drivers. The native
        # dependencies also invoke clang-cl, which ignores bare -ffile flags.
        for step in builder._windows(release=True):
            if not step.argv or step.argv[0] != 'cargo':
                continue
            for target in ('x86_64', 'aarch64'):
                self.assertEqual(step.env.get(f'CC_{target}_pc_windows_msvc'), 'clang-cl')
                self.assertEqual(step.env.get(f'CXX_{target}_pc_windows_msvc'), 'clang-cl')
            for variable in ('CFLAGS', 'CXXFLAGS'):
                flags = shlex.split(step.env[variable])
                for kind in ('macro', 'debug'):
                    at = next(i for i, flag in enumerate(flags)
                              if flag.startswith(f'-f{kind}-prefix-map='))
                    self.assertEqual(flags[at - 1], '-Xclang')

    @unittest.skipUnless(sys.platform == 'win32', 'Requires the real Windows compiler')
    def test_windows_compiler_remaps_narrow_and_wide_file_macros(self):
        compiler = shutil.which('clang-cl')
        self.assertIsNotNone(compiler, 'Windows builds require clang-cl')
        # Under the home directory deliberately, so the real production prefix
        # applies. Include a space to exercise cc-rs/CMake flag tokenisation.
        with tempfile.TemporaryDirectory(prefix='xveil remap ', dir=Path.home()) as directory:
            source = Path(directory) / 'probe.cc'
            source.write_text('#include <cstdio>\n'
                              '#define W2(x) L##x\n#define W(x) W2(x)\n'
                              'int main(){volatile const wchar_t* w=W(__FILE__);'
                              'std::puts(__FILE__);return w[0]==0;}\n')
            binary = Path(directory) / 'probe.exe'
            # Caller-supplied correct flags must not mask a missing remap in
            # the Flutter step (which also builds the native VPN helper).
            with mock.patch.dict(os.environ, {'CFLAGS': '', 'CXXFLAGS': ''}):
                producers = {
                    'FFI': windows_native_env(),
                    'Flutter': next(step.env for step in builder._windows(release=True)
                                    if step.argv[:3] == ['flutter', 'build', 'windows']),
                }
            for role, additions in producers.items():
                with self.subTest(role=role):
                    env = {**os.environ, **additions}
                    subprocess.run([compiler, '/nologo', str(source), '/Fe' + str(binary),
                                    *shlex.split(env['CXXFLAGS'])], cwd=directory, env=env,
                                   capture_output=True, check=True)
                    ran = subprocess.run([str(binary)], capture_output=True, check=True, text=True)
                    self.assertTrue(ran.stdout.strip().replace('\\', '/').startswith('/build/'))
                    self.assertTrue(ran.stdout.strip().endswith('probe.cc'))
                    for prefix in (str(Path.home()), str(Path.home()).replace('\\', '/')):
                        for encoding in ('utf-8', 'utf-16-le'):
                            self.assertNotIn(prefix.encode(encoding), binary.read_bytes())


if __name__ == '__main__':
    unittest.main()
