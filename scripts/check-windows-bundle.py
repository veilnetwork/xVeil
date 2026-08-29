#!/usr/bin/env python3
"""Every binary in a Windows bundle belongs to that bundle's architecture.

Two questions, both asked of the ARTEFACT rather than of the build that
produced it:

  1. does every PE here carry the machine this bundle claims? An x64 DLL in an
     arm64 bundle is either dead weight or a load failure, and it looks like
     neither from the outside -- the file name is identical.

  2. is each Visual C++ runtime DLL present exactly when something needs it?
     The old check demanded all three unconditionally, with the note "every
     binary here imports it". True on x64. On ARM64, VCRUNTIME140_1.dll is not
     imported by anything: it carries x64-only exception-handling helpers. The
     redist ships an x64 copy of it even under the arm64 directory, so the
     unconditional demand was satisfied by a file of the wrong machine, and the
     check passed while shipping it.

Usage: check-windows-bundle.py <bundle-root> <arch: x64|arm64>
"""

from __future__ import annotations

import os
import struct
import sys

MACHINES = {0x8664: "x64", 0xAA64: "arm64", 0x1C0: "arm", 0x14C: "x86"}
RUNTIME_DLLS = ("MSVCP140.dll", "VCRUNTIME140.dll", "VCRUNTIME140_1.dll")


def pe_machine(path: str) -> str | None:
    """The machine field, or None when this is not a PE at all."""
    try:
        with open(path, "rb") as fh:
            head = fh.read(0x200)
        if head[:2] != b"MZ":
            return None
        off = struct.unpack_from("<I", head, 0x3C)[0]
        if head[off:off + 4] != b"PE\0\0":
            return None
        return MACHINES.get(struct.unpack_from("<H", head, off + 4)[0], "?")
    except (OSError, struct.error):
        return None


def references(path: str, name: str) -> bool:
    """Does this binary name that DLL anywhere in its bytes?

    A scan, not an import-table parse, and deliberately so: it errs towards
    demanding a runtime DLL that might not be needed, never towards dropping
    one that is.
    """
    needle = name.lower().encode()
    try:
        with open(path, "rb") as fh:
            return needle in fh.read().lower()
    except OSError:
        return False


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    root, arch = sys.argv[1], sys.argv[2]
    if not os.path.isdir(root):
        print(f"::error::no bundle at {root}", file=sys.stderr)
        return 1

    binaries = []
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            if name.lower().endswith((".exe", ".dll")):
                binaries.append(os.path.join(dirpath, name))

    # Vacuity guard. Everything below passes on an empty directory.
    if len(binaries) < 5:
        print(
            f"::error::only {len(binaries)} binaries under {root} — this is not "
            "a bundle, and every check here would pass on it",
            file=sys.stderr,
        )
        return 1

    problems = []
    for path in sorted(binaries):
        machine = pe_machine(path)
        if machine is None:
            continue
        if machine != arch:
            problems.append(
                f"{os.path.relpath(path, root)} is {machine}, not {arch}"
            )

    for dll in RUNTIME_DLLS:
        present = os.path.join(root, dll)
        have = os.path.isfile(present)
        needed = any(
            references(p, dll)
            for p in binaries
            if os.path.basename(p).lower() != dll.lower()
        )
        if needed and not have:
            problems.append(
                f"{dll} is referenced by this bundle and missing from it — on a "
                "Windows without the Visual C++ Redistributable the app dies at "
                "startup naming some other DLL entirely"
            )
        if have and not needed:
            problems.append(
                f"{dll} is in the bundle and nothing here references it"
            )
        if needed and have:
            print(f"  ok {dll} (referenced, present)")
        elif not needed and not have:
            print(f"  ok {dll} (not needed on {arch})")

    if problems:
        for p in problems:
            print(f"::error::{p}", file=sys.stderr)
        return 1

    print(f"  ok {len(binaries)} binaries, all {arch}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
