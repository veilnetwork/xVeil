#!/usr/bin/env python3
"""Remove native debug records before signing a release macOS app.

strip -S preserves code and ordinary symbols, unlike stripping all symbols.
Xcode's external dSYMs are not part of the app and remain untouched. The caller
must sign modified code objects and the app afterwards. This does not sanitize
runtime strings: Rust/C/Swift prefix maps and artifact privacy checks still apply.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import sys


THIN_MAGIC = {b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf"}


def is_macho(path: Path) -> bool:
    with path.open("rb") as stream:
        head = stream.read(8)
        if head[:4] in THIN_MAGIC:
            return True
        if head[:4] not in {b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"} or len(head) < 8:
            return False
        count = struct.unpack(">I", head[4:])[0]
        if not 1 <= count <= 16:
            return False  # e.g. a Java class, which shares the fat magic
        entry = stream.read(32 if head[:4].endswith(b"\xbf") else 20)
        if len(entry) < 20:
            return False
        offset = struct.unpack_from(">Q" if head[:4].endswith(b"\xbf") else ">I", entry, 8)[0]
        stream.seek(offset)
        return stream.read(4) in THIN_MAGIC


def strip_app(app: Path) -> dict[str, int]:
    root = app.resolve(strict=True)
    if not root.is_dir() or root.suffix != ".app":
        raise ValueError("expected an app directory")
    binaries = set()
    # Validate every link before modifying anything; do not traverse aliases.
    def walk_error(error):
        raise error

    for directory, directories, filenames in os.walk(root, followlinks=False, onerror=walk_error):
        base = Path(directory)
        for child in list(directories):
            path = base / child
            if not path.resolve(strict=True).is_relative_to(root):
                raise ValueError("app contains an external link")
            if child.endswith(".dSYM"):
                raise ValueError("debug sidecars must be outside app")
            if path.is_symlink():
                directories.remove(child)
        for child in filenames:
            path = base / child
            resolved = path.resolve(strict=True)
            if not resolved.is_relative_to(root):
                raise ValueError("app contains an external link")
            if path.is_file() and is_macho(path):
                binaries.add(resolved)
    if not binaries:
        raise ValueError("app contains no Mach-O binaries")
    for binary in sorted(binaries):
        before = subprocess.run(["xcrun", "nm", "-gjU", str(binary)],
                                capture_output=True, check=True).stdout
        subprocess.run(["xcrun", "strip", "-S", str(binary)], capture_output=True, check=True)
        after = subprocess.run(["xcrun", "nm", "-gjU", str(binary)],
                               capture_output=True, check=True).stdout
        if before != after:
            raise ValueError("native exported symbols changed")
    return {"binaries_processed": len(binaries)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args(argv)
    try:
        result = strip_app(args.app)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(json.dumps({"complete": False, "error_type": type(error).__name__}))
        return 2
    print(json.dumps({"complete": True, **result}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
