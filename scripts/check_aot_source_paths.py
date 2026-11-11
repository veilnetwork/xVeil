#!/usr/bin/env python3
"""Find absolute home-directory source URIs in AOT files and ZIP members.

This is one artifact privacy check, not a general secret scanner. It deliberately
reports counts only: printing a matched URI would itself disclose the builder.
Inputs are never changed. ZIP members are read without extracting their paths.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
import zipfile

_HOME_URI = re.compile(
    rb"file:///(?:[a-z](?::|%3a)/users/|users/|home/)"
    rb"[^/\x00\s\"<>]{1,255}/",
    re.IGNORECASE,
)
DEFAULT_LIMIT = 1024 * 1024 * 1024


def source_home_uri_count(data: bytes) -> int:
    """Count ordinary byte-encoded file URIs, including percent-encoded owners.

    Do not decode arbitrary binary data as text or treat a missing *known*
    username as privacy evidence. This checks URI syntax, not an identity list.
    Other encodings and non-URI secrets require additional checks.
    """
    return sum(1 for _ in _HOME_URI.finditer(data))


def scan_artifact(path: Path, *, byte_limit: int = DEFAULT_LIMIT) -> dict[str, int]:
    if byte_limit <= 0:
        raise ValueError("invalid scan budget")
    total = members = matches = 0

    def consume(data: bytes) -> None:
        nonlocal total, members, matches
        total += len(data)
        if total > byte_limit:
            raise ValueError("artifact scan budget exceeded")
        members += 1
        matches += source_home_uri_count(data)

    def scan_file(file: Path) -> None:
        nonlocal total
        if zipfile.is_zipfile(file):
            with zipfile.ZipFile(file) as archive:
                entries = [e for e in archive.infolist() if not e.is_dir()]
                if total + sum(e.file_size for e in entries) > byte_limit:
                    raise ValueError("artifact scan budget exceeded")
                for entry in entries:
                    consume(archive.read(entry))
        else:
            # A damaged ZIP must not quietly pass as an opaque compressed file.
            if file.suffix.lower() in {".zip", ".apk", ".aab", ".ipa"}:
                raise ValueError("invalid artifact archive")
            if total + file.stat().st_size > byte_limit:
                raise ValueError("artifact scan budget exceeded")
            consume(file.read_bytes())

    if path.is_dir():
        base = path.resolve(strict=True)

        def scan_error(error: OSError) -> None:
            raise error

        # pathlib glob/is_file can silently suppress unreadable or broken
        # entries. A partial walk must not be reported as a complete clean scan.
        for root, directories, filenames in os.walk(path, onerror=scan_error):
            for name in list(directories):
                directory = Path(root) / name
                if not directory.resolve(strict=True).is_relative_to(base):
                    raise ValueError("external artifact directory link")
                if directory.is_symlink() or (
                    hasattr(directory, "is_junction") and directory.is_junction()
                ):
                    # Internal targets are reached by their real directory;
                    # do not follow aliases or cycles a second time.
                    directories.remove(name)
            for name in sorted(filenames):
                file = Path(root) / name
                if not file.resolve(strict=True).is_relative_to(base):
                    raise ValueError("external artifact file link")
                scan_file(file)
    else:
        scan_file(path)
    if not members:
        raise ValueError("no artifact members scanned")
    return {"members_scanned": members, "bytes_scanned": total,
            "source_home_uri_occurrences": matches}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", nargs="+", type=Path)
    args = parser.parse_args(argv)
    results = []
    try:
        for path in args.artifacts:
            results.append(scan_artifact(path))
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile) as error:
        # Never echo filenames or error messages containing an input path.
        print(json.dumps({"complete": False, "error_type": type(error).__name__}))
        return 2
    print(json.dumps({"complete": True, "artifacts": results}))
    return int(any(r["source_home_uri_occurrences"] for r in results))


if __name__ == "__main__":
    sys.exit(main())
