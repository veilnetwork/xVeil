#!/usr/bin/env python3
"""Checks for the parts of the build support that only misbehave on Windows.

A Windows runner is a slow place to learn that the plan cannot start its own
tools, so the two resolution rules are pinned here instead. Both came from a
real release build: `flutter` failed as `[WinError 2] The system cannot find
the file specified` after have() had already reported it present, and the
whisper step failed with "Windows Subsystem for Linux has no installed
distributions" because `bash` found the WSL launcher in System32.

    python3 scripts/test-build-support.py

Windows is simulated: os.name and the lookups resolve() performs are replaced,
so these run anywhere. That makes them a check of the rule, not of a machine.
"""

from __future__ import annotations

import os
import time
import os.path
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import xveil_build_support as bs  # noqa: E402

GIT = r"C:\Program Files\Git\cmd\git.exe"
GIT_BASH = r"C:\Program Files\Git\bin\bash.exe"
WSL_BASH = r"C:\Windows\System32\bash.exe"
FLUTTER_BAT = r"C:\flutter\bin\flutter.bat"

failures: list[str] = []


def check(name: str, actual: object, expected: object) -> None:
    if actual == expected:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}: got {actual!r}, expected {expected!r}")
        failures.append(name)


class FakeWindows:
    """os.name, which() and exists() as they look on a Windows runner."""

    def __init__(self, which: dict[str, str], present: set[str]) -> None:
        self.which, self.present = which, present

    def __enter__(self):
        # dirname belongs in here too: __exit__ used to "restore" it from
        # os.path.__dict__, which by then already held the replacement, so the
        # first block left every later caller with the Windows lambda.
        self.saved = (
            os.name, shutil.which, os.path.exists, os.path.join, os.path.dirname
        )
        os.name = "nt"
        shutil.which = lambda tool: self.which.get(tool)
        os.path.exists = lambda path: path in self.present
        # ntpath semantics without importing a second os: the fake paths are
        # already backslash-separated, so joining with one keeps them valid.
        os.path.join = lambda *parts: "\\".join(p.rstrip("\\") for p in parts)
        os.path.dirname = lambda path: path.rsplit("\\", 1)[0]
        return self

    def __exit__(self, *_exc) -> None:
        (
            os.name, shutil.which, os.path.exists, os.path.join, os.path.dirname
        ) = self.saved


print("newer_source()")


def _touch(path: str, when: int) -> str:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("x")
    os.utime(path, (when, when))
    return path


with tempfile.TemporaryDirectory() as tmp:
    crates = os.path.join(tmp, "crates")
    source = _touch(os.path.join(crates, "space", "log.rs"), 1000)
    manifest = _touch(os.path.join(tmp, "Cargo.toml"), 1000)
    # A file cargo does not compile from, in a directory cargo writes to.
    _touch(os.path.join(crates, "target", "leftover.rs"), 9000)
    _touch(os.path.join(crates, "README.md"), 9000)
    artifact = _touch(os.path.join(tmp, "libthing.so"), 2000)

    check("an artifact newer than its sources is current",
          bs.newer_source(artifact, [crates, manifest]), None)
    check("target/ is output, not source",
          bs.newer_source(artifact, [crates]), None)

    # A crate's tests/ is its own cargo target and is never linked into the
    # library, so touching one must not condemn the .so.
    crate = os.path.join(crates, "thing")
    _touch(os.path.join(crate, "Cargo.toml"), 1000)
    _touch(os.path.join(crate, "tests", "integration.rs"), 9000)
    _touch(os.path.join(crate, "benches", "throughput.rs"), 9000)
    crate_src = _touch(os.path.join(crate, "src", "lib.rs"), 1000)
    check("a crate's tests/ and benches/ are not library inputs",
          bs.newer_source(artifact, [crates]), None)
    # …but its src/ is, and that is the whole point.
    os.utime(crate_src, (9000, 9000))
    check("a crate's src/ still condemns a stale artifact",
          bs.newer_source(artifact, [crates]), crate_src)
    os.utime(crate_src, (1000, 1000))

    os.utime(source, (3000, 3000))
    check("a source touched after the build is named",
          bs.newer_source(artifact, [crates, manifest]), source)

    os.utime(source, (1000, 1000))
    os.utime(manifest, (3000, 3000))
    check("a manifest named directly is weighed too",
          bs.newer_source(artifact, [crates, manifest]), manifest)

    # Absence is a different question, with a different message, and answering
    # it here would report a MISSING library as a current one.
    check("a missing artifact is not called current",
          bs.newer_source(os.path.join(tmp, "nope.so"), [crates]), None)

print("resolve() on Windows")

# A .bat is invisible to CreateProcess by bare name; the full path is not.
with FakeWindows({"flutter": FLUTTER_BAT}, set()):
    check("flutter resolves to the .bat path", bs.resolve("flutter"), FLUTTER_BAT)

# System32\bash.exe is the WSL launcher. Git's bash is the one that can run a
# build script, and it sits two levels up from git.exe plus bin\.
with FakeWindows({"bash": WSL_BASH, "git": GIT}, {GIT_BASH}):
    check("bash steps away from the WSL launcher", bs.resolve("bash"), GIT_BASH)

# Without Git there is nothing better to offer; returning the WSL launcher at
# least fails with its own message rather than a missing-file error.
with FakeWindows({"bash": WSL_BASH}, set()):
    check("bash keeps the WSL launcher when Git is absent", bs.resolve("bash"), WSL_BASH)

# A bash that is already Git's must not be second-guessed.
with FakeWindows({"bash": GIT_BASH, "git": GIT}, {GIT_BASH}):
    check("a non-System32 bash is left alone", bs.resolve("bash"), GIT_BASH)

print("resolve() elsewhere")
# On POSIX the name is the whole answer, and rewriting it would break every
# caller that expects PATH to decide.
check("names pass through unchanged", bs.resolve("flutter"), "flutter")
check("bash passes through unchanged", bs.resolve("bash"), "bash")

print("the media symbol check runs through the same resolved bash")

# builder.py grew a check that shells out on its own rather than through a
# Step, so nothing resolved argv[0] for it. That is not a skipped check on
# Windows, it is a WRONG one: the WSL launcher exits 1, and 1 is the code the
# caller reads as "the engine is missing symbols" — so an Android release built
# on Windows would fail, blaming a good engine and naming symbols nobody read.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import builder  # noqa: E402

with FakeWindows({"bash": WSL_BASH, "git": GIT}, {GIT_BASH}):
    argv = builder._symbol_check_argv("lib\\arm64-v8a\\libveil_media.so")
check("the symbol check does not run the WSL launcher", argv[0], GIT_BASH)
check("it still passes the script and the library", len(argv), 3)
check("and the library is the last argument", argv[2], "lib\\arm64-v8a\\libveil_media.so")



# ── The Android freshness gate asks only about ABIs that ship ────────────────
#
# The release APK is arm64-only, and gradle rebuilds only that slice, so an
# An ABI staged but not packaged is permanently older than the tree. Failing on
# it blocks every correct build — and a gate that blocks correct builds is one
# somebody switches off, after which it protects nothing.
#
# The unshipped ABI here is `x86`: both Rust libraries build for it (it is in
# hidden-volume's ABIS_DEFAULT and in veil_flutter's abiFilters), so it really
# does turn up in a jniLibs tree, and it is not in _RELEASE_APK_ABIS. It used
# to be armeabi-v7a — which stopped being an example on 2026-08-28, when the
# media engine and the whisper wrapper were built for it and it started
# shipping. A fixture that quietly describes the old world is how a test goes
# on passing about something that is no longer true.
import builder  # noqa: E402

with tempfile.TemporaryDirectory() as _tmp:
    _source = os.path.join(_tmp, "src.rs")
    _stage = os.path.join(_tmp, "jniLibs")
    for _abi in ("arm64-v8a", "x86"):
        os.makedirs(os.path.join(_stage, _abi))
        with open(os.path.join(_stage, _abi, "lib.so"), "w") as _fh:
            _fh.write("x")
    with open(_source, "w") as _fh:
        _fh.write("fn main() {}")
    # Both .so files predate the source; only the shipped one is refreshed.
    _future = time.time() + 10
    os.utime(os.path.join(_stage, "arm64-v8a", "lib.so"), (_future, _future))

    _held = builder._ANDROID_NATIVE
    builder._ANDROID_NATIVE = (
        ("lib.so", os.path.relpath(_stage, builder.ROOT), [_source], "rebuild"),
    )
    try:
        builder._check_android_native_fresh()
        _blocked = False
    except RuntimeError:
        _blocked = True
    check("a stale ABI that is not packaged does not fail the build", _blocked, False)

    # And the shipped ABI is still checked — otherwise the fix would have
    # turned the gate off rather than aimed it.
    _past = time.time() - 100
    os.utime(os.path.join(_stage, "arm64-v8a", "lib.so"), (_past, _past))
    try:
        builder._check_android_native_fresh()
        _blocked = False
    except RuntimeError:
        _blocked = True
    check("a stale SHIPPED ABI still fails the build", _blocked, True)
    builder._ANDROID_NATIVE = _held



# The stray-APK check asks about the DIRECTORY, once — not "everything that is
# not the ABI I am looking at". Asked inside the per-ABI loop it was right
# while exactly one APK shipped and became self-contradictory the moment three
# did: each shipped APK accused the other two of being leftovers, and the
# build refused artifacts it had just produced correctly.
import zipfile  # noqa: E402

with tempfile.TemporaryDirectory() as _tmp:
    _apk_dir = os.path.join(_tmp, "build", "app", "outputs", "flutter-apk")
    os.makedirs(_apk_dir)
    _need = list(builder._REQUIRED_EVERY_ABI) + [builder._MEDIA_SO]

    def _make_apk(_name: str, _abi: str) -> None:
        with zipfile.ZipFile(os.path.join(_apk_dir, _name), "w") as _z:
            for _so in _need:
                _z.writestr(f"lib/{_abi}/{_so}", "x")

    for _abi in builder._RELEASE_APK_ABIS:
        _make_apk(f"app-{_abi}-release.apk", _abi)

    _held_root, _held_sym = builder.ROOT, builder._media_symbols_problem
    builder.ROOT = _tmp
    # The symbol check reads a real ELF; these fixtures are zip files with
    # one-byte members, and what is under test here is the file list.
    builder._media_symbols_problem = lambda **_kw: []
    try:
        try:
            builder._check_android_native_libs()
            _refused = False
        except RuntimeError:
            _refused = True
        check("every shipped ABI's APK is accepted together", _refused, False)

        # And an ABI that is NOT shipped is still caught: the fix must aim the
        # gate, not switch it off.
        _make_apk("app-x86-release.apk", "x86")
        try:
            builder._check_android_native_libs()
            _caught = ""
        except RuntimeError as _exc:
            _caught = str(_exc)
        check(
            "an APK for an ABI this build does not ship is refused",
            "app-x86-release.apk" in _caught,
            True,
        )
    finally:
        builder.ROOT, builder._media_symbols_problem = _held_root, _held_sym


# The verdict, LAST. It used to sit above the checks appended after it, so a
# failure there printed "FAIL" and the script still exited 0 — a gate that
# reports and does not gate. Anything added below this line is outside the
# summary again, so add checks ABOVE it.
if failures:
    print(f"\nFAIL: {len(failures)} check(s): {', '.join(failures)}")
    sys.exit(1)
print("\nOK: all checks passed")
