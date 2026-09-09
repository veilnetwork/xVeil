#!/usr/bin/env python3
"""The oldest Linux a bundle can start on, asked of the bundle.

A Flutter Linux bundle carries its own libraries and takes libc, libstdc++ and
the GTK stack from the host. Which HOST that can be is decided by the machine
the bundle was built on, and nothing in the release said so: the x64 bundle was
built on whatever `ubuntu-latest` pointed at, so the floor rose with the runner
image. It rose to Ubuntu 24.04, and a user on 22.04 -- the current LTS at the
time -- got

    ./xveil: /lib/x86_64-linux-gnu/libstdc++.so.6: version `GLIBCXX_3.4.32'
    not found (required by ./xveil)

with nothing in the release notes to say the machine was too old, because
nobody had asked.

The musl bundle has had proof of this shape since it existed: its job starts
the app inside Alpine and fails if it does not reach GTK. This is the same
question for the glibc bundle, asked statically -- a runner cannot install an
older glibc to try it on, but every ELF states the versions it needs.

What is checked: every ELF in the bundle (the executable and every shared
object, including the ones we did not build) is read for its version
REQUIREMENTS, and the highest of each family is compared against the declared
ceiling. A file that raises the floor is named, because the answer to "why is
the floor 2.38" is usually one prebuilt.

Usage:
    check-linux-floor.py <bundle-root> --max-glibc 2.35 --max-glibcxx 3.4.30
    check-linux-floor.py <bundle-root> --report      # print, never fail
    check-linux-floor.py --self-test                 # the parser, on fixtures
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

# `Name: GLIBC_2.38`, `Name: GLIBCXX_3.4.32`, `Name: CXXABI_1.3.13`.
NEED = re.compile(r"\bName:\s+([A-Z_]+[A-Z])_([0-9][0-9.]*)\b")

# The families a host distribution decides. `GCC_*` and `CXXABI_*` travel with
# libstdc++ and move with it, so they are reported and not separately gated:
# two ceilings a reader can hold in their head beat five they cannot.
GATED = ("GLIBC", "GLIBCXX")


def version_tuple(text: str) -> tuple[int, ...]:
    """`3.4.30` -> (3, 4, 30).

    Numeric on purpose. Compared as strings, `3.4.30` sorts BELOW `3.4.9` --
    which is the exact pair this project ships against, so a lexicographic
    comparison would have called a 3.4.30 requirement satisfied by a 3.4.9
    host and reported a floor that does not exist.
    """
    return tuple(int(part) for part in text.split(".") if part != "")


def is_elf(path: str) -> bool:
    try:
        with open(path, "rb") as handle:
            return handle.read(4) == b"\x7fELF"
    except OSError:
        return False


def needs_of(path: str, readelf: str) -> dict[str, str]:
    """The highest version required per family, for one ELF."""
    try:
        out = subprocess.run(
            [readelf, "--wide", "--version-info", path],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as why:
        # A missing readelf is not "no requirements found". Said plainly rather
        # than as a traceback, because the difference between "the floor is
        # low" and "nothing was read" is the whole value of this check.
        raise SystemExit(
            f"cannot run {readelf!r} ({why}) -- install binutils or pass "
            f"--readelf; this check refuses to report a floor it did not read"
        ) from why
    if out.returncode != 0:
        raise SystemExit(
            f"{path}: {readelf} exited {out.returncode} -- this check cannot "
            f"read the file it exists to read:\n{out.stderr.strip()}"
        )
    return highest(out.stdout)


def highest(readelf_output: str) -> dict[str, str]:
    """The highest version per family in one `readelf --version-info` dump."""
    best: dict[str, str] = {}
    for family, version in NEED.findall(readelf_output):
        current = best.get(family)
        if current is None or version_tuple(version) > version_tuple(current):
            best[family] = version
    return best


def walk(root: str) -> list[str]:
    found = []
    for base, _dirs, files in os.walk(root):
        for name in sorted(files):
            path = os.path.join(base, name)
            if os.path.islink(path):
                continue
            if is_elf(path):
                found.append(path)
    return sorted(found)


SELF_TEST_FIXTURE = """
Version needs section '.gnu.version_r' contains 2 entries:
 Addr: 0x0000000000001234  Offset: 0x001234  Link: 6 (.dynstr)
  000000: Version: 1  File: libstdc++.so.6  Cnt: 3
  0x0010:   Name: GLIBCXX_3.4.9  Flags: none  Version: 14
  0x0020:   Name: GLIBCXX_3.4.30  Flags: none  Version: 13
  0x0030:   Name: CXXABI_1.3.13  Flags: none  Version: 12
  0x0040: Version: 1  File: libc.so.6  Cnt: 2
  0x0050:   Name: GLIBC_2.14  Flags: none  Version: 4
  0x0060:   Name: GLIBC_2.38  Flags: none  Version: 3
"""


def self_test() -> None:
    got = highest(SELF_TEST_FIXTURE)
    assert got.get("GLIBCXX") == "3.4.30", (
        f"3.4.30 lost to 3.4.9: the comparison is lexicographic, and every "
        f"floor this reports would be wrong low ({got})"
    )
    assert got.get("GLIBC") == "2.38", got
    assert got.get("CXXABI") == "1.3.13", got
    assert version_tuple("2.9") < version_tuple("2.10"), "2.10 read as older than 2.9"
    assert highest("nothing here") == {}, "a file with no needs claims a floor"
    # And the gate itself: a ceiling BELOW the fixture must refuse it, or the
    # comparison is decorative.
    assert version_tuple(got["GLIBC"]) > version_tuple("2.35")
    assert not version_tuple(got["GLIBCXX"]) > version_tuple("3.4.30")
    print("self-test: the parser reads versions numerically and gates on them")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", nargs="?", help="the bundle directory")
    parser.add_argument("--max-glibc", default=None)
    parser.add_argument("--max-glibcxx", default=None)
    parser.add_argument("--report", action="store_true", help="print, never fail")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--readelf", default=os.environ.get("READELF", "readelf"))
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0
    if not args.bundle:
        parser.error("a bundle directory is required")
    if not os.path.isdir(args.bundle):
        parser.error(f"{args.bundle} is not a directory")

    elves = walk(args.bundle)
    if not elves:
        print(f"::error::no ELF files under {args.bundle} -- this check read nothing")
        return 1

    ceilings = {"GLIBC": args.max_glibc, "GLIBCXX": args.max_glibcxx}
    worst: dict[str, tuple[str, str]] = {}
    for path in elves:
        for family, version in needs_of(path, args.readelf).items():
            current = worst.get(family)
            if current is None or version_tuple(version) > version_tuple(current[0]):
                worst[family] = (version, path)

    print(f"{len(elves)} ELF file(s) under {args.bundle}")
    for family in sorted(worst):
        version, path = worst[family]
        rel = os.path.relpath(path, args.bundle)
        print(f"  {family}_{version:<10} highest, from {rel}")

    if args.report:
        return 0

    failed = False
    for family in GATED:
        ceiling = ceilings.get(family)
        if ceiling is None:
            continue
        found = worst.get(family)
        if found is None:
            # Nothing requires it. Not a pass to celebrate: say so, because a
            # bundle whose libc requirement vanished is a bundle this check
            # stopped reading.
            print(f"::warning::nothing in the bundle requires {family}_*")
            continue
        version, path = found
        if version_tuple(version) > version_tuple(ceiling):
            rel = os.path.relpath(path, args.bundle)
            print(
                f"::error::{rel} requires {family}_{version}, above the declared "
                f"floor {family}_{ceiling}. The bundle will not start on the "
                f"oldest Linux this release claims to support -- build it on an "
                f"older base, or raise the floor deliberately and say so in the "
                f"release notes."
            )
            failed = True
    if failed:
        return 1
    print("the bundle starts on the declared floor")
    return 0


if __name__ == "__main__":
    sys.exit(main())
