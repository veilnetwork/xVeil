import json
import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from aot_build import (CHILD_ENV, MARKER, artifact_directory, child_marker,
                       _publish_directory, _preserve_symbols, run_neutral_build)

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import builder

VERSIONS = {"XVEIL_VEIL_VERSION": "v1-fixture", "XVEIL_HV_VERSION": "v2-fixture"}


class AotBuildTest(unittest.TestCase):
    def setUp(self):
        base = os.environ.get("XVEIL_AOT_TEST_ROOT") or (
            os.environ.get("ProgramData") if os.name == "nt" else
            "/private/tmp" if Path("/private/tmp").is_dir() else "/tmp")
        self.temp = tempfile.TemporaryDirectory(dir=base)
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.source = self.base / "original"
        (self.source / "lib").mkdir(parents=True)
        (self.source / "lib/main.dart").write_text("original source")
        (self.source / "pubspec.yaml").write_text("name: fixture\n")
        (self.source / "pubspec.lock").write_text("locked input")
        (self.source / "builder.py").write_text("# controlled child command fixture\n")
        self.output = self.source / artifact_directory("windows")
        self.output.mkdir(parents=True)
        (self.output / "previous").write_bytes(b"previous artifact")
        self.calls = []

    def command(self, argv, *, cwd, env):
        self.calls.append((argv, Path(cwd), dict(env)))
        if "pub" in argv:
            self.assertIn("--enforce-lockfile", argv)
            config = cwd / ".dart_tool/package_config.json"
            config.parent.mkdir()
            config.write_text(json.dumps({"configVersion": 2, "packages": [
                {"name": "fixture", "rootUri": "../", "packageUri": "lib/"}]}))
        else:
            with patch.dict(os.environ, env):
                marker = child_marker(cwd)
            self.assertEqual(marker["native_versions"], VERSIONS)
            self.assertEqual(env["XVEIL_VEIL_VERSION"], VERSIONS["XVEIL_VEIL_VERSION"])
            self.assertEqual(env["XVEIL_AOT_PACKAGE_ROOTS_READY"], "1")
            output = cwd / artifact_directory("windows")
            output.mkdir(parents=True)
            (output / "current").write_bytes(b"new artifact")
            (cwd / "lib/main.dart").write_text("child mutation")

    def build(self, command=None):
        with patch("aot_build._run_command", side_effect=command or self.command):
            return run_neutral_build(self.source, "windows", native_versions=VERSIONS,
                                     workspace_base=self.base)

    def assert_original_and_cleanup(self):
        self.assertEqual((self.source / "lib/main.dart").read_text(), "original source")
        self.assertEqual((self.source / "pubspec.lock").read_text(), "locked input")
        self.assertFalse(list(self.base.glob("xveil-aot-*")))
        self.assertFalse(list(self.output.parent.glob(".xveil-aot-*")))

    def test_verified_child_export_and_cleanup(self):
        result = self.build()
        self.assertEqual((self.output / "current").read_bytes(), b"new artifact")
        self.assertFalse((self.output / "previous").exists())
        self.assertEqual(result["privacy"]["current_home_path_occurrences"], 0)
        self.assertEqual(len(self.calls), 2)
        if os.name == "nt":
            from aot_package_roots import _ps_literal
            command = (
                "$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value; "
                "$paths=@(" + _ps_literal(str(self.output)) + ","
                + _ps_literal(str(self.output / "current")) + "); "
                "@($paths|ForEach-Object {$acl=if([IO.Directory]::Exists($_)) {"
                "[IO.Directory]::GetAccessControl($_)}else{[IO.File]::GetAccessControl($_)}; "
                "@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])"
                "|Where-Object {$_.IdentityReference.Value -eq $sid -and "
                "$_.AccessControlType -eq 'Allow'}).Count -gt 0})|ConvertTo-Json -Compress"
            )
            check = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive",
                                    "-Command", command], capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(check.stdout), [True, True])
        self.assert_original_and_cleanup()

    def test_failed_child_keeps_previous_artifact(self):
        def command(argv, **kwargs):
            self.command(argv, **kwargs)
            if "--release" in argv:
                raise subprocess.CalledProcessError(1, ["fixture-child"])
        with self.assertRaises(subprocess.CalledProcessError):
            self.build(command)
        self.assertEqual((self.output / "previous").read_bytes(), b"previous artifact")
        self.assert_original_and_cleanup()

    def test_uri_or_native_leak_never_replaces_previous_artifact(self):
        for leak in [b"file:///Users/build-alias/private/source.dart",
                     (str(Path.home()) + "/.cargo/private.rs").encode("utf-16le")]:
            with self.subTest(native=leak.startswith(b"f") is False):
                def command(argv, *, cwd, env):
                    self.command(argv, cwd=cwd, env=env)
                    if "--release" in argv:
                        (cwd / artifact_directory("windows") / "current").write_bytes(leak)
                with self.assertRaises(ValueError):
                    self.build(command)
                self.assertEqual((self.output / "previous").read_bytes(), b"previous artifact")
                self.assert_original_and_cleanup()

    def test_rename_failure_restores_previous_directory(self):
        original_rename = Path.rename
        def rename(path, destination):
            if path.name.startswith(".xveil-aot-publish-"):
                raise PermissionError("fixture publish failure")
            return original_rename(path, destination)
        with patch.object(Path, "rename", rename):
            with self.assertRaises(PermissionError):
                self.build()
        self.assertEqual((self.output / "previous").read_bytes(), b"previous artifact")
        self.assert_original_and_cleanup()

    def test_native_outputs_copied_without_reusing_cargo_cache(self):
        configured = self.base / "producer-target"
        (configured / "release/deps").mkdir(parents=True)
        (configured / "release/veilclient_ffi.dll").write_bytes(b"verified producer")
        (configured / "release/deps/cache").write_bytes(b"not an input")
        fallback = self.source / "third_party/veil/target/release"
        fallback.mkdir(parents=True)
        (fallback / "veilclient_ffi.dll").write_bytes(b"old fallback")
        def command(argv, *, cwd, env):
            self.command(argv, cwd=cwd, env=env)
            if "--release" in argv:
                target = Path(env["CARGO_TARGET_DIR"])
                self.assertNotEqual(target, configured)
                self.assertEqual((target / "release/veilclient_ffi.dll").read_bytes(), b"verified producer")
                self.assertFalse((target / "release/deps").exists())
                self.assertEqual((cwd / "third_party/veil/target").resolve(), target)
        with patch.dict(os.environ, {"CARGO_TARGET_DIR": str(configured)}):
            self.build(command)
        self.assertEqual((fallback / "veilclient_ffi.dll").read_bytes(), b"old fallback")
        self.assert_original_and_cleanup()

    def test_absolute_internal_alias_is_not_exported_as_broken_link(self):
        source = self.base / "artifact"
        source.mkdir()
        (source / "data").write_bytes(b"content")
        try:
            (source / "alias").symlink_to(source / "data")
        except OSError:
            self.skipTest("host cannot create symlink fixture")
        with self.assertRaises(ValueError):
            _publish_directory(source, self.output)
        self.assertEqual((self.output / "previous").read_bytes(), b"previous artifact")

    def test_child_marker_rejects_wrong_source_or_cargo_target(self):
        file = self.source / MARKER
        file.parent.mkdir()
        marker = {"schema": 1, "source": str(self.source), "cargo_target": str(self.base / "target")}
        file.write_text(json.dumps(marker))
        with patch.dict(os.environ, {"CARGO_TARGET_DIR": "wrong"}):
            with self.assertRaises(ValueError):
                child_marker(self.source)
        marker["source"] = str(self.base / "other")
        file.write_text(json.dumps(marker))
        with self.assertRaises(ValueError):
            child_marker(self.source)

    def test_child_keeps_native_version_labels_without_original_git_metadata(self):
        cargo = self.base / "cargo-target"
        cargo.mkdir()
        file = self.source / MARKER
        file.parent.mkdir()
        file.write_text(json.dumps({"schema": 1, "source": str(self.source),
                                   "cargo_target": str(cargo), "native_versions": VERSIONS}))
        with patch.dict(os.environ, {CHILD_ENV: "1", "CARGO_TARGET_DIR": str(cargo)}), \
             patch.object(builder, "ROOT", str(self.source)), \
             patch.object(builder.subprocess, "check_output", side_effect=AssertionError("must not inspect original Git")):
            self.assertEqual(builder._native_version_defines(), [
                "--dart-define=" + key + "=" + value for key, value in VERSIONS.items()])

    def test_debug_sidecars_are_saved_outside_published_app(self):
        staged = self.base / "staged"
        debug = staged / "build/macos/Build/Products/Release/fixture.app.dSYM/Contents/Resources/DWARF/fixture"
        debug.parent.mkdir(parents=True)
        debug.write_bytes(b"private native debug symbols")
        saved = _preserve_symbols(staged, self.source, "macos")
        self.addCleanup(shutil.rmtree, saved)
        copied = saved / debug.relative_to(staged / "build/macos")
        self.assertEqual(copied.read_bytes(), debug.read_bytes())
        self.assertTrue(saved.is_relative_to(self.source / "build/private-symbols"))
        self.assertFalse(list(self.output.rglob("*.dSYM")))


class BuilderAotPlanTest(unittest.TestCase):
    def plan(self, target, release, child=False, signed=True):
        with patch.object(builder, "have", return_value=True), \
             patch.object(builder, "_apple_signing_available", return_value=signed), \
             patch.object(builder, "_arm64_windows_cmake_env"), \
             patch.object(builder, "_native_version_defines", return_value=[]), \
             patch("aot_build.child_marker", return_value={}), \
             patch.dict(os.environ, {CHILD_ENV: "1" if child else ""}):
            return builder.plan(target, release=release)

    def test_all_release_paths_use_workspace_and_all_children_keep_gate(self):
        for target in ["android", "windows", "linux", "macos", "ios"]:
            for signed in [True, False] if target in {"macos", "ios"} else [True]:
                with self.subTest(target=target, signed=signed):
                    parent = self.plan(target, True, signed=signed)
                    self.assertTrue(parent[-1].title.startswith("neutral AOT"))
                    self.assertFalse(any(builder._is_aot_flutter_step(step) for step in parent))
                    child = self.plan(target, True, child=True, signed=signed)
                    self.assertEqual(child[-1].title, "artifact source-path privacy")
                    for step in child:
                        if step.argv[:2] == ["flutter", "build"]:
                            self.assertIn("--no-pub", step.argv)
                        self.assertFalse(step.argv and step.argv[0] == "cargo")

    def test_debug_paths_still_build_in_place(self):
        for target in ["android", "windows", "linux", "macos", "ios"]:
            steps = self.plan(target, False)
            self.assertTrue(any(builder._is_aot_flutter_step(step) for step in steps))
            self.assertFalse(any(step.title.startswith("neutral AOT") for step in steps))

    def test_release_preview_shows_child_checks_without_executing_them(self):
        from xveil_build_support import run
        steps = self.plan("android", True)
        output = io.StringIO()
        with patch("subprocess.run", side_effect=AssertionError("dry run executed a command")), \
             patch("aot_build.run_neutral_build", side_effect=AssertionError("dry run built")), \
             contextlib.redirect_stdout(output):
            run(steps, dry_run=True)
        self.assertIn("flutter build apk --release --split-per-abi", output.getvalue())
        self.assertIn("signing check", output.getvalue())


if __name__ == "__main__":
    unittest.main()
