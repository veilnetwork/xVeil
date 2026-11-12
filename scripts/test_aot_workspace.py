from pathlib import Path
import os
import shutil
import json
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from aot_workspace import prepare_workspace


class AotWorkspaceTest(unittest.TestCase):
    def setUp(self):
        neutral = os.environ.get("XVEIL_AOT_TEST_ROOT") or (
            os.environ.get("ProgramData") if os.name == "nt" else
            "/private/tmp" if Path("/private/tmp").is_dir() else "/tmp")
        self.temp = tempfile.TemporaryDirectory(dir=neutral)
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.source = self.base / "original"
        self.source.mkdir()
        (self.source / "pubspec.yaml").write_text("name: fixture\n")

    def write(self, name, data=b"fixture"):
        file = self.source / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(data)

    def prepare(self, **kwargs):
        result = prepare_workspace(self.source, self.base, **kwargs)
        self.addCleanup(shutil.rmtree, result["workspace"])
        return result, Path(result["source"])

    def test_real_inputs_and_staged_native_files_are_independent_copies(self):
        self.write("lib/main.dart")
        self.write("assets/prod/config.txt")
        self.write("android/key.properties")
        self.write("third_party/veil/flutter/veil_media/macos/Frameworks/libveil_media.dylib")
        self.write("third_party/veil/crates/module/src/lib.rs")
        self.write("third_party/hidden-volume/experimental/flutter_plugin/plugin/lib.dll")
        first, staged = self.prepare()
        self.assertEqual(first["files"], 7)
        self.assertEqual((staged / "assets/prod/config.txt").read_bytes(), b"fixture")
        (staged / "lib/main.dart").write_bytes(b"build mutation")
        self.assertEqual((self.source / "lib/main.dart").read_bytes(), b"fixture")
        second, _ = self.prepare()
        self.assertEqual(first["input_sha256"], second["input_sha256"])
        if os.name != "nt":
            self.assertEqual(Path(first["workspace"]).stat().st_mode & 0o777, 0o700)
        else:
            from aot_package_roots import _ps_literal
            script = (
                "$sections=[Security.AccessControl.AccessControlSections]::Access -bor "
                "[Security.AccessControl.AccessControlSections]::Owner; "
                "$acl=[IO.Directory]::GetAccessControl(" + _ps_literal(first["workspace"]) + ", $sections); "
                "$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value; "
                "@{Protected=$acl.AreAccessRulesProtected;Owner=$acl.GetOwner("
                "[Security.Principal.SecurityIdentifier]).Value -eq $sid; "
                "Rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])"
                "|ForEach-Object {$_.IdentityReference.Value})}|ConvertTo-Json -Compress"
            )
            result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
                                    capture_output=True, text=True, check=True)
            acl = json.loads(result.stdout)
            self.assertTrue(acl["Protected"])
            self.assertTrue(acl["Owner"])
            self.assertEqual(len(acl["Rules"]), 1)

    def test_build_git_and_stand_caches_do_not_enter_copy(self):
        for name in [".git/config", "build/huge", "artifacts/stand.store", ".dev-stand/data",
                     "lib/.dart_tool/cache", "third_party/veil/target/object",
                     "third_party/veil/debug/object", "third_party/veil/.git/config",
                     "third_party/hidden-volume/build/output", "macos/Pods/plugin",
                     "ios/.symlinks/plugins/cached", "macos/Flutter/ephemeral/cached",
                     "macos/Runner.xcodeproj/xcuserdata/local/settings"]:
            self.write(name)
        result, staged = self.prepare()
        self.assertEqual(result["files"], 1)
        self.assertFalse((staged / ".git").exists())
        self.assertFalse((staged / "build").exists())

    def test_failure_removes_only_owned_partial_workspace(self):
        self.write("lib/main.dart", b"oversized")
        sentinel = self.base / "keep"
        sentinel.write_text("original")
        before = set(self.base.iterdir())
        with self.assertRaises(ValueError):
            prepare_workspace(self.source, self.base, byte_limit=1)
        self.assertEqual(set(self.base.iterdir()), before)
        with patch("aot_workspace._protect_workspace", side_effect=OSError("fixture")):
            with self.assertRaises(OSError):
                prepare_workspace(self.source, self.base)
        self.assertEqual(set(self.base.iterdir()), before)
        self.assertEqual(sentinel.read_text(), "original")

    def test_base_inside_source_is_rejected_before_copy(self):
        with self.assertRaises(ValueError):
            prepare_workspace(self.source, self.source)
        self.assertFalse(list(self.source.glob("xveil-aot-*")))

    def test_directory_alias_does_not_copy_or_remove_external_data(self):
        from aot_package_roots import _directory_alias
        outside = self.base / "external"
        outside.mkdir()
        (outside / "keep").write_text("external data")
        (self.source / "lib").mkdir()
        _directory_alias(self.source / "lib/alias", outside)
        before = set(self.base.iterdir())
        # A false/missing newer pathlib predicate must not make a Windows
        # junction traversable on older supported Python installations.
        with patch.object(Path, "is_junction", return_value=False, create=True):
            with self.assertRaises(ValueError):
                prepare_workspace(self.source, self.base)
        self.assertEqual(set(self.base.iterdir()), before)
        self.assertEqual((outside / "keep").read_text(), "external data")


if __name__ == "__main__":
    unittest.main()
