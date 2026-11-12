#!/usr/bin/env python3
"""Regression coverage for artifact source-URI privacy checks."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "aot_source_paths", Path(__file__).with_name("check_aot_source_paths.py"))
assert spec and spec.loader
scanner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scanner)


class AotSourcePathsTest(unittest.TestCase):
    def test_role_counts_do_not_reflect_member_names_or_protected_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'app.apk'
            home = '/home/private-builder'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('lib/arm64-v8a/libapp.so', b'file:///home/private-builder/main.dart')
                archive.writestr('lib/x86_64/libhidden_volume_ffi.so', (home + '/native.rs').encode())
                archive.writestr('secret-member-private-builder', (home + '/other').encode())
            result = scanner.scan_artifact(path, current_home=home, include_roles=True)
            self.assertEqual(result['path_roles'], [
                {'role': 'dart_aot', 'abi': 'arm64-v8a', 'source_home_uris': 1, 'current_home_paths': 1},
                {'role': 'other', 'abi': 'unknown', 'source_home_uris': 0, 'current_home_paths': 1},
                {'role': 'storage_native', 'abi': 'x86_64', 'source_home_uris': 0, 'current_home_paths': 1},
            ])
            serialized = json.dumps(result)
            self.assertNotIn('private-builder', serialized)
            self.assertNotIn('secret-member', serialized)
            self.assertNotIn(tmp, serialized)

    def test_build_failure_exposes_only_counts_and_fixed_categories(self):
        import aot_build
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with zipfile.ZipFile(root / 'app.apk', 'w') as archive:
                archive.writestr('lib/arm64-v8a/libveil_media.so',
                                 b'file:///home/private-builder/native.cc')
            with self.assertRaises(ValueError) as failure:
                aot_build._check_paths(root)
            message = str(failure.exception)
            self.assertIn('media_native', message)
            self.assertIn('source_home_uris', message)
            self.assertNotIn('private-builder', message)
            self.assertNotIn(tmp, message)

    def test_owners_do_not_have_to_be_known(self):
        for uri in [
            b"file:///Users/fixture-builder/project/lib/main.dart",
            b"file:///home/second-builder/cache/library.dart",
            b"file:///C:/Users/third-builder/AppData/Local/Pub/file.dart",
            b"file:///d%3a/users/build%20alias/sdk/library.dart",
        ]:
            with self.subTest(uri=uri):
                self.assertEqual(scanner.source_home_uri_count(b"\0" + uri + b"\0"), 1)

    def test_neutral_and_package_uris_are_allowed(self):
        data = (b"file:///build/src/lib/main.dart\0package:xveil/main.dart\0"
                b"https://example.invalid/Users/public/docs\0dart:core")
        self.assertEqual(scanner.source_home_uri_count(data), 0)

    def test_native_home_paths_and_encodings_require_the_additional_check(self):
        for home, path in [
            ("/Users/build alias", "/Users/build alias/.cargo/src/native.rs"),
            ("/Users/build alias", "file:///Users/build%20alias/cache/native.cc"),
            (r"C:\Users\build alias", r"C:\Users\build alias\AppData\native.cc"),
            (r"C:\Users\build alias", "file:///C:/Users/build%20alias/cache/native.cc"),
        ]:
            for encoding in ("utf-8", "utf-16le", "utf-16be"):
                with self.subTest(encoding=encoding, windows=home.startswith("C:")):
                    self.assertEqual(scanner.current_home_path_count(path.encode(encoding), home), 1)
        self.assertEqual(scanner.current_home_path_count(b"/build/src/main.rs", "/Users/build-alias"), 0)

    def test_native_only_leak_fails_cli_without_printing_owner(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "native.so"
            path.write_bytes(b"panic at /Users/private-builder/.cargo/library.rs\0")
            self.assertEqual(scanner.scan_artifact(path)["source_home_uri_occurrences"], 0)
            with patch.object(scanner.Path, "home", return_value=Path("/Users/private-builder")):
                with redirect_stdout(output := io.StringIO()):
                    self.assertEqual(scanner.main(["--check-current-home", str(path)]), 1)
            result = json.loads(output.getvalue())
            self.assertEqual(result["artifacts"][0]["current_home_path_occurrences"], 1)
            self.assertNotIn("private-builder", output.getvalue())
            self.assertNotIn(tmp, output.getvalue())

    def test_compressed_members_are_scanned_and_never_extracted(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "app.apk"
            with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("lib/arm64-v8a/libapp.so", b"file:///Users/build-alias/src/main.dart")
                archive.writestr("../../never-extract", b"safe")
            result = scanner.scan_artifact(path)
            self.assertEqual(result["members_scanned"], 2)
            self.assertEqual(result["source_home_uri_occurrences"], 1)
            self.assertEqual(list(Path(tmp).iterdir()), [path])

    def test_app_directory_is_scanned(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "fixture.app"
            app.mkdir()
            (app / "App").write_bytes(b"file:///home/build-alias/src/main.dart")
            self.assertEqual(scanner.scan_artifact(app)["source_home_uri_occurrences"], 1)

    def test_budget_and_invalid_archives_do_not_return_false_clean(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "app.apk"
            path.write_bytes(b"invalid")
            with self.assertRaises(ValueError):
                scanner.scan_artifact(path)
            with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("app.so", b"x" * 100)
            with self.assertRaises(ValueError):
                scanner.scan_artifact(path, byte_limit=50)
            empty = Path(tmp) / "empty"
            empty.mkdir()
            with self.assertRaises(ValueError):
                scanner.scan_artifact(empty)

    def test_broken_members_cannot_hide_behind_a_clean_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "clean.so").write_bytes(b"safe")
            try:
                (root / "missing.so").symlink_to(root / "absent-target")
            except OSError:
                self.skipTest("host cannot create symbolic-link fixture")
            with self.assertRaises(OSError):
                scanner.scan_artifact(root)
            (root / "missing.so").unlink()
            (root / "alias").symlink_to(root, target_is_directory=True)
            self.assertEqual(scanner.scan_artifact(root)["members_scanned"], 1)
            with tempfile.TemporaryDirectory() as outside:
                (root / "external").symlink_to(outside, target_is_directory=True)
                with self.assertRaises(ValueError):
                    scanner.scan_artifact(root)

    def test_output_contains_counts_and_no_match_or_input_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "private-builder-artifact.so"
            path.write_bytes(b"file:///Users/private-builder/source/lib/main.dart")
            output = io.StringIO()
            with redirect_stdout(output):
                self.assertEqual(scanner.main([str(path)]), 1)
            result = json.loads(output.getvalue())
            self.assertTrue(result["complete"])
            self.assertNotIn("private-builder", output.getvalue())
            self.assertNotIn(tmp, output.getvalue())
            with redirect_stdout(output := io.StringIO()):
                self.assertEqual(scanner.main([str(path.with_name("private-missing"))]), 2)
            self.assertFalse(json.loads(output.getvalue())["complete"])
            self.assertNotIn("private-missing", output.getvalue())
            self.assertNotIn(tmp, output.getvalue())


if __name__ == "__main__":
    unittest.main()
