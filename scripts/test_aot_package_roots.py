#!/usr/bin/env python3
from copy import deepcopy
import base64
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from aot_package_roots import plan_package_roots, remap_workspace, _ps_literal
import aot_package_roots


class AotPackageRootsTest(unittest.TestCase):
    def neutral_temporary_directory(self):
        root = os.environ.get("XVEIL_AOT_TEST_ROOT")
        if not root:
            root = os.environ.get("ProgramData") if os.name == "nt" else (
                "/private/tmp" if Path("/private/tmp").is_dir() else "/tmp")
        return tempfile.TemporaryDirectory(dir=root)

    def test_unix_roots_preserve_package_contract(self):
        original = {"configVersion": 2, "generator": "pub", "packages": [
            {"name": "app", "rootUri": "../", "packageUri": "lib/", "languageVersion": "3.0"},
            {"name": "ffi", "rootUri": "file:///Users/build-alias/cache/ffi/", "packageUri": "lib/"},
        ]}
        before = deepcopy(original)
        result, aliases = plan_package_roots(original,
            config_uri="file:///Users/build-alias/project/.dart_tool/package_config.json",
            source_uri="file:///Users/build-alias/project/", staged_uri="file:///tmp/neutral/source/",
            aliases_uri="file:///tmp/neutral/deps/")
        self.assertEqual(original, before)
        self.assertEqual(result["packages"][0]["rootUri"], "file:///tmp/neutral/source/")
        self.assertEqual(result["packages"][0]["languageVersion"], "3.0")
        self.assertEqual(result["generator"], "pub")
        self.assertEqual(aliases, [("file:///tmp/neutral/deps/ffi/", "file:///Users/build-alias/cache/ffi/")])
        self.assertEqual(result["packages"][1]["packageUri"], "lib/")

    def test_windows_drive_case_and_encoded_directories(self):
        cfg = {"configVersion": 2, "packages": [
            {"name": "app", "rootUri": "file:///c:/users/build%20alias/PROJECT/"},
            {"name": "sdk", "rootUri": "file:///C:/Users/build%20alias/cache/sdk/"},
            {"name": "already", "rootUri": "file:///D:/Build/project/local/"},
        ]}
        result, links = plan_package_roots(cfg,
            config_uri="file:///C:/Users/build%20alias/project/.dart_tool/package_config.json",
            source_uri="file:///C:/Users/build%20alias/project/",
            staged_uri="file:///D:/Build/project/", aliases_uri="file:///D:/Build/deps/")
        self.assertEqual(result["packages"][0]["rootUri"], "file:///D:/Build/project/")
        self.assertEqual(result["packages"][2]["rootUri"], "file:///D:/Build/project/local/")
        self.assertEqual(len(links), 1)

    def test_prefix_collision_is_an_external_package(self):
        cfg = {"configVersion": 2, "packages": [{"name": "external", "rootUri": "file:///tmp/project-other/"}]}
        result, links = plan_package_roots(cfg, config_uri="file:///tmp/project/config.json",
            source_uri="file:///tmp/project/", staged_uri="file:///tmp/staged/", aliases_uri="file:///tmp/deps/")
        self.assertEqual(len(links), 1)
        self.assertEqual(result["packages"][0]["rootUri"], "file:///tmp/deps/external/")

    def test_plan_is_idempotent_and_rejects_non_neutral_or_overlapping_roots(self):
        cfg = {"configVersion": 2, "packages": [{"name": "lib", "rootUri": "file:///tmp/deps/lib/"}]}
        options = dict(config_uri="file:///tmp/staged/config.json", source_uri="file:///tmp/source/",
                       staged_uri="file:///tmp/staged/", aliases_uri="file:///tmp/deps/")
        result, links = plan_package_roots(cfg, **options)
        self.assertEqual(links, [])
        self.assertEqual(result, cfg)
        for changed in [{"staged_uri": "file:///tmp/source/staged/"},
                        {"staged_uri": "file:///tmp/"},
                        {"aliases_uri": "file:///Users/build-alias/deps/"},
                        {"staged_uri": "file:///home/build-alias/project/"}]:
            with self.assertRaises(ValueError):
                plan_package_roots(cfg, **(options | changed))

    def test_staged_only_write_and_read_through_alias(self):
        with self.neutral_temporary_directory() as tmp:
            base = Path(tmp).resolve()
            source = base / "original"
            staged = base / "neutral/source"
            package = base / "package's $(literal)"
            source.mkdir(); (staged / ".dart_tool").mkdir(parents=True); (package / "lib").mkdir(parents=True)
            (package / "lib/value.dart").write_text("const value = 42;")
            config = {"configVersion": 2, "packages": [
                {"name": "app", "rootUri": source.as_uri() + "/", "packageUri": "lib/"},
                {"name": "dep", "rootUri": package.as_uri() + "/", "packageUri": "lib/"},
            ]}
            path = staged / ".dart_tool/package_config.json"
            path.write_text(json.dumps(config)); original = json.dumps(config)
            (source / "original.json").write_text(original)
            result = remap_workspace(source, staged, base / "neutral/deps")
            self.assertEqual(result, {"packages": 2, "external_aliases": 1})
            self.assertEqual((base / "neutral/deps/dep/lib/value.dart").read_text(), "const value = 42;")
            self.assertEqual((source / "original.json").read_text(), original)
            self.assertEqual(remap_workspace(source, staged, base / "neutral/deps")["external_aliases"], 0)
            self.assertFalse(list(path.parent.glob("package_config.xveil-*")))

    def test_failed_alias_does_not_publish_partial_configuration(self):
        with self.neutral_temporary_directory() as tmp:
            base = Path(tmp).resolve()
            source = base / "original"
            staged = base / "neutral/source"
            source.mkdir(); (staged / ".dart_tool").mkdir(parents=True)
            config_path = staged / ".dart_tool/package_config.json"
            original = json.dumps({"configVersion": 2, "packages": [
                {"name": "missing", "rootUri": (base / "absent").as_uri() + "/"},
            ]}).encode()
            config_path.write_bytes(original)
            with self.assertRaises(ValueError):
                remap_workspace(source, staged, base / "neutral/deps")
            self.assertEqual(config_path.read_bytes(), original)
            self.assertFalse(list(config_path.parent.glob("package_config.xveil-*")))

    def test_failed_atomic_replace_preserves_config_and_removes_temporary_file(self):
        with self.neutral_temporary_directory() as tmp:
            base = Path(tmp).resolve()
            source = base / "original"
            staged = base / "neutral/source"
            source.mkdir(); (staged / ".dart_tool").mkdir(parents=True)
            config_path = staged / ".dart_tool/package_config.json"
            original = json.dumps({"configVersion": 2, "packages": [
                {"name": "app", "rootUri": source.as_uri() + "/"},
            ]}).encode()
            config_path.write_bytes(original)
            with patch.object(Path, "replace", side_effect=PermissionError("fixture")):
                with self.assertRaises(PermissionError):
                    remap_workspace(source, staged, base / "neutral/deps")
            self.assertEqual(config_path.read_bytes(), original)
            self.assertFalse(list(config_path.parent.glob("package_config.xveil-*")))

    def test_literal_windows_arguments_do_not_expand(self):
        self.assertEqual(_ps_literal("a'b$(literal)%VALUE%"), "'a''b$(literal)%VALUE%'")

    def test_windows_package_set_uses_one_process_with_paths_as_data(self):
        with self.neutral_temporary_directory() as tmp:
            base = Path(tmp).resolve()
            source, staged = base / 'original', base / 'neutral/source'
            package = base / "package's $(literal) & r\u00e9sum\u00e9"
            source.mkdir(); (staged / '.dart_tool').mkdir(parents=True); package.mkdir()
            (package / 'marker').write_text('fixture')
            config = {'configVersion': 2, 'packages': [
                {'name': 'dep' + str(i), 'rootUri': package.as_uri() + '/'} for i in range(32)]}
            file = staged / '.dart_tool/package_config.json'
            file.write_text(json.dumps(config))
            calls = []

            def create_aliases(argv, **options):
                command = base64.b64decode(argv[-1]).decode('utf-16le')
                calls.append(command)
                if 'input' in options:
                    pairs = json.loads(options['input'])
                else:
                    # Exercise the former single-process-per-package implementation
                    # too: this guard fails on its 32 invocations, not a missing API.
                    match = re.search(r"-Path '((?:''|[^'])*)' -Target '((?:''|[^'])*)'", command)
                    self.assertIsNotNone(match)
                    pairs = [{'alias': match[1].replace("''", "'"),
                              'target': match[2].replace("''", "'")}]
                for pair in pairs:
                    shutil.copytree(pair['target'], pair['alias'])
                return SimpleNamespace(returncode=0, stdout=json.dumps(
                    {'count': len(pairs), 'create_ms': 0}).encode())

            with patch.object(aot_package_roots, 'os', SimpleNamespace(name='nt')), \
                    patch.object(aot_package_roots.subprocess, 'run', side_effect=create_aliases):
                result = remap_workspace(source, staged, base / 'neutral/deps')
            self.assertEqual(result['external_aliases'], 32)
            self.assertEqual(len(calls), 1)
            self.assertNotIn(str(package), calls[0])
            self.assertEqual((base / 'neutral/deps/dep31/marker').read_text(), 'fixture')

    def test_many_native_aliases_observe_later_source_changes(self):
        with self.neutral_temporary_directory() as tmp:
            base = Path(tmp).resolve()
            source, staged = base / 'original', base / 'neutral/source'
            package = base / "package's $(literal) & r\u00e9sum\u00e9"
            source.mkdir(); (staged / '.dart_tool').mkdir(parents=True); package.mkdir()
            (package / 'marker').write_text('before')
            file = staged / '.dart_tool/package_config.json'
            file.write_text(json.dumps({'configVersion': 2, 'packages': [
                {'name': 'dep' + str(i), 'rootUri': package.as_uri() + '/'} for i in range(32)]}))
            self.assertEqual(remap_workspace(source, staged, base / 'neutral/deps')['external_aliases'], 32)
            (package / 'marker').write_text('after')
            for i in range(32):
                self.assertEqual((base / 'neutral/deps' / ('dep' + str(i)) / 'marker').read_text(), 'after')
            self.assertEqual(remap_workspace(source, staged, base / 'neutral/deps')['external_aliases'], 0)

    def test_failed_windows_batch_preserves_config_without_exposing_provider_errors(self):
        for failure in ['provider', 'timeout']:
            with self.subTest(failure=failure), self.neutral_temporary_directory() as tmp:
                base = Path(tmp).resolve()
                source, staged, package = base / 'original', base / 'neutral/source', base / 'package'
                source.mkdir(); (staged / '.dart_tool').mkdir(parents=True); package.mkdir()
                file = staged / '.dart_tool/package_config.json'
                original = json.dumps({'configVersion': 2, 'packages': [
                    {'name': 'dep', 'rootUri': package.as_uri() + '/'}]}).encode()
                file.write_bytes(original)
                options = {'return_value': SimpleNamespace(returncode=1, stderr=b'protected-provider-detail')}
                if failure == 'timeout':
                    options = {'side_effect': subprocess.TimeoutExpired('protected-provider-detail', 180)}
                with patch.object(aot_package_roots, 'os', SimpleNamespace(name='nt')), \
                        patch.object(aot_package_roots.subprocess, 'run', **options):
                    with self.assertRaises(OSError) as error:
                        remap_workspace(source, staged, base / 'neutral/deps')
                self.assertNotIn('protected-provider-detail', str(error.exception))
                self.assertEqual(file.read_bytes(), original)
                self.assertFalse(list(file.parent.glob('package_config.xveil-*')))

    def test_malformed_configuration_has_a_controlled_failure(self):
        options = dict(config_uri="file:///tmp/staged/.dart_tool/package_config.json",
                       source_uri="file:///tmp/original/", staged_uri="file:///tmp/staged/",
                       aliases_uri="file:///tmp/deps/")
        for config in [[], {"configVersion": 2, "packages": [None]},
                       {"configVersion": 2, "packages": [{"name": "../escape", "rootUri": "../"}]}]:
            with self.assertRaises(ValueError):
                plan_package_roots(config, **options)


if __name__ == "__main__":
    unittest.main()
