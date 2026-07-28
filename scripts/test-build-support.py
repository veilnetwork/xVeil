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
import os.path
import shutil
import sys

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
        self.saved = (os.name, shutil.which, os.path.exists, os.path.join)
        os.name = "nt"
        shutil.which = lambda tool: self.which.get(tool)
        os.path.exists = lambda path: path in self.present
        # ntpath semantics without importing a second os: the fake paths are
        # already backslash-separated, so joining with one keeps them valid.
        os.path.join = lambda *parts: "\\".join(p.rstrip("\\") for p in parts)
        os.path.dirname = lambda path: path.rsplit("\\", 1)[0]
        return self

    def __exit__(self, *_exc) -> None:
        os.name, shutil.which, os.path.exists, os.path.join = self.saved
        os.path.dirname = os.path.__dict__["dirname"]


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

if failures:
    print(f"\nFAIL: {len(failures)} check(s): {', '.join(failures)}")
    sys.exit(1)
print("\nOK: all checks passed")
