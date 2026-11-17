"""Exercise local release admission and packaged bytes through builder entrypoints."""
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT))
import builder
import xveil_native_deps as deps

spec = importlib.util.spec_from_file_location(
    'builder_media_test_provenance', PROJECT / 'scripts/verify-media-provenance.py')
media = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media)


class BuilderMediaProvenanceTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / 'pubspec.yaml').write_text('version: 1.2.3+4\n')
        self.source = self.root / 'third_party/veil/flutter/veil_media/src'
        self.source.mkdir(parents=True)
        self.implementation = self.source / 'engine.cc'
        self.implementation.write_text('int capture() { return 0; }\n')
        self.paths = {
            'android': [Path(builder._MEDIA_STAGE_DIR) / abi / builder._MEDIA_SO
                        for abi in builder._MEDIA_ABIS],
            'linux': [Path(builder._LINUX_ENGINE_STAGE)],
            'windows': [Path(builder._WINDOWS_ENGINE_STAGE)],
        }
        for paths in self.paths.values():
            for path in paths:
                binary = self.root / path
                binary.parent.mkdir(parents=True, exist_ok=True)
                binary.write_bytes(b'current engine with unchanged ABI')
                media._native.record_build(
                    self.source, binary, media.source_digest(self.source))
        self.enterContext(mock.patch.object(builder, 'ROOT', str(self.root)))
        # All output below comes from the actual builder entrypoints.
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))

    def before_compile(self, platform, release):
        plan = getattr(builder, '_' + platform)(release)
        for step in plan:
            if step.argv:
                return
            if step.call is not None:
                step.call()
        self.fail('plan never reaches a compiler')

    def test_current_records_allow_release_compilation(self):
        for platform in self.paths:
            with self.subTest(platform=platform):
                self.before_compile(platform, True)

    def test_release_refuses_old_source_with_unchanged_abi(self):
        self.implementation.write_text('int capture() { return 1; }\n')
        for platform in self.paths:
            with self.subTest(platform=platform):
                with self.assertRaisesRegex(RuntimeError, 'media.*provenance'):
                    self.before_compile(platform, True)

    def test_release_refuses_replaced_staged_binary(self):
        for platform, paths in self.paths.items():
            with self.subTest(platform=platform):
                (self.root / paths[0]).write_bytes(b'older binary, same exports')
                with self.assertRaisesRegex(RuntimeError, 'media.*provenance'):
                    self.before_compile(platform, True)

    def test_release_refuses_missing_provenance(self):
        for platform, paths in self.paths.items():
            with self.subTest(platform=platform):
                binary = self.root / paths[0]
                binary.with_name(binary.name + '.provenance').unlink()
                with self.assertRaisesRegex(RuntimeError, 'media.*provenance'):
                    self.before_compile(platform, True)

    def test_debug_presence_admission_does_not_require_release_records(self):
        for paths in self.paths.values():
            for path in paths:
                binary = self.root / path
                binary.with_name(binary.name + '.provenance').unlink()
        for platform in self.paths:
            with self.subTest(platform=platform):
                self.before_compile(platform, False)

    def artifact(self, platform, payload):
        if platform == 'android':
            abi = builder._MEDIA_ABIS[0]
            apk = self.root / 'fixture.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.writestr(f'lib/{abi}/{builder._MEDIA_SO}', payload)
            with mock.patch.object(builder, '_media_symbols_verdict', return_value=[]):
                return builder._media_symbols_problem(bundle_path=str(apk), abi=abi)
        directory = self.root / 'bundle' / platform
        name = builder._LINUX_ENGINE_SO if platform == 'linux' else builder._WINDOWS_ENGINE_DLL
        binary = directory / 'lib' / name if platform == 'linux' else directory / name
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.write_bytes(payload)
        getattr(builder, '_check_' + platform + '_engine')(str(directory))
        return []

    def test_packaged_bytes_match_the_verified_record(self):
        for platform, paths in self.paths.items():
            with self.subTest(platform=platform):
                payload = (self.root / paths[0]).read_bytes()
                self.assertEqual(self.artifact(platform, payload), [])

    def test_an_unused_nested_engine_does_not_satisfy_the_loader_location(self):
        # The app CMake files install Linux plugin libraries under lib/ and
        # Windows libraries beside the runner. An arbitrary nested copy is
        # not the library the loader will open.
        for platform in ['linux', 'windows']:
            with self.subTest(platform=platform):
                directory = self.root / 'unused-bundle' / platform
                binary = directory / 'unused' / self.paths[platform][0].name
                binary.parent.mkdir(parents=True)
                binary.write_bytes((self.root / self.paths[platform][0]).read_bytes())
                with self.assertRaisesRegex(RuntimeError, 'MISSING'):
                    getattr(builder, '_check_' + platform + '_engine')(str(directory))

    def test_stale_packaged_copy_is_rejected_despite_current_staging(self):
        for platform in self.paths:
            with self.subTest(platform=platform):
                if platform == 'android':
                    problems = self.artifact(platform, b'old package, same exports')
                    self.assertTrue(problems)
                    self.assertTrue(any('provenance' in p for p in problems))
                else:
                    with self.assertRaisesRegex(RuntimeError, 'media.*provenance'):
                        self.artifact(platform, b'old package, same exports')

    def fetch_fixture(self, failure=None):
        engine = deps.ENGINES['android']
        binary = self.root / self.paths['android'][0]
        record = binary.with_name(binary.name + '.provenance').read_bytes()
        payload = binary.read_bytes()
        if failure == 'source':
            self.implementation.write_text('int capture() { return 1; }\n')
        elif failure == 'binary':
            payload = b'older downloaded engine'
        assets = [{'name': engine.asset, 'browser_download_url': 'fixture:binary'}]
        if failure != 'missing-record':
            assets.append({'name': engine.asset + '.provenance',
                           'browser_download_url': 'fixture:record'})
        self.enterContext(mock.patch.object(deps, 'ROOT', str(self.root)))
        self.enterContext(mock.patch.object(deps, 'api_json', return_value=(200, {'assets': assets})))
        self.enterContext(mock.patch.object(deps, '_get', side_effect=lambda url, *_a, **_k:
                                          io.BytesIO(payload if url == 'fixture:binary' else record)))
        return engine, payload, record

    def test_fetcher_stages_both_verified_inputs(self):
        engine, payload, record = self.fetch_fixture()
        directory = self.root / 'fetched'
        get = deps._get
        def observe_download(url, *args, **kwargs):
            if directory.exists():
                self.assertEqual(list(directory.glob('.engine-stage-*/' + engine.filename)), [])
            return get(url, *args, **kwargs)
        self.enterContext(mock.patch.object(deps, '_get', side_effect=observe_download))
        path = Path(deps._download_release_asset('engine-fixture', engine, str(directory)))
        self.assertEqual(path.read_bytes(), payload)
        sidecar = path.with_name(path.name + '.provenance')
        self.assertTrue(sidecar.exists())
        self.assertEqual(sidecar.read_bytes(), record)
        self.assertEqual(list(directory.glob('.engine-stage-*')), [])

    def test_unverified_download_keeps_the_previous_pair(self):
        for failure in ['source', 'binary', 'missing-record']:
            with self.subTest(failure=failure):
                self.implementation.write_text('int capture() { return 0; }\n')
                engine, _, _ = self.fetch_fixture(failure)
                directory = self.root / ('fetch-' + failure)
                directory.mkdir()
                binary = directory / engine.filename
                sidecar = binary.with_name(binary.name + '.provenance')
                binary.write_bytes(b'previous engine')
                sidecar.write_bytes(b'previous record')
                with self.assertRaises(deps.Abort):
                    deps._download_release_asset('engine-fixture', engine, str(directory))
                self.assertEqual(binary.read_bytes(), b'previous engine')
                self.assertEqual(sidecar.read_bytes(), b'previous record')
                self.assertEqual(list(directory.glob('.engine-stage-*')), [])

    def test_cached_fetcher_does_not_accept_symbols_without_current_source(self):
        with mock.patch.object(deps, 'ROOT', str(self.root)), \
             mock.patch.object(deps, 'OUTCOMES', []), \
             mock.patch.object(deps, '_check_symbols', return_value=(True, 'symbols match', [])), \
             mock.patch.object(deps, 'api_json', side_effect=AssertionError('cache must not fetch')):
            deps.fetch_engine('android')
            self.assertTrue(deps.OUTCOMES[-1].got)
            self.implementation.write_text('int capture() { return 1; }\n')
            deps.fetch_engine('android')
            self.assertFalse(deps.OUTCOMES[-1].got)

    def run_artifact(self, failure=None):
        engine = deps.ENGINES['android']
        binary = self.root / self.paths['android'][0]
        payload = binary.read_bytes() if failure != 'binary' else b'changed artifact bytes'
        record = binary.with_name(binary.name + '.provenance').read_bytes()
        contents = io.BytesIO()
        with zipfile.ZipFile(contents, 'w') as archive:
            archive.writestr('engine/' + engine.filename, payload)
            if failure != 'missing-record':
                archive.writestr('engine/' + engine.filename + '.provenance', record)
        opener = mock.Mock()
        opener.open.return_value = io.BytesIO(contents.getvalue())
        directory = self.root / ('run-' + str(failure))
        directory.mkdir()
        previous = directory / engine.filename
        previous.write_bytes(b'previous engine')
        previous.with_name(previous.name + '.provenance').write_bytes(b'previous record')
        self.enterContext(mock.patch.object(deps, 'ROOT', str(self.root)))
        self.enterContext(mock.patch.object(deps.urllib.request, 'build_opener', return_value=opener))
        return engine, directory, payload, record

    def test_run_artifact_keeps_binary_and_record_together(self):
        engine, directory, payload, record = self.run_artifact()
        verify = getattr(deps, 'verify_media_engine', None)
        def observe_verify(binary, **kwargs):
            self.assertNotIn(Path(binary).suffix, {'.so', '.dll'})
            return verify(binary, **kwargs)
        scope = (mock.patch.object(deps, 'verify_media_engine', side_effect=observe_verify)
                 if verify else contextlib.nullcontext())
        with scope:
            path = Path(deps._download_artifact(1, engine, str(directory), 'fixture-token'))
        self.assertEqual(path.read_bytes(), payload)
        sidecar = path.with_name(path.name + '.provenance')
        self.assertTrue(sidecar.exists())
        self.assertEqual(sidecar.read_bytes(), record)
        self.assertFalse((directory / '.engine.zip').exists())

    def test_unverified_run_artifact_keeps_the_previous_pair(self):
        for failure in ['binary', 'missing-record']:
            with self.subTest(failure=failure):
                engine, directory, _, _ = self.run_artifact(failure)
                with self.assertRaises(deps.Abort):
                    deps._download_artifact(1, engine, str(directory), 'fixture-token')
                previous = directory / engine.filename
                self.assertEqual(previous.read_bytes(), b'previous engine')
                self.assertEqual(previous.with_name(previous.name + '.provenance').read_bytes(), b'previous record')
                self.assertFalse((directory / '.engine.zip').exists())
                self.assertEqual(list(directory.glob('.engine-stage-*')), [])


if __name__ == '__main__':
    unittest.main()
