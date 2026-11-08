"""Refuse to publish an artifact that carries a forbidden string.

Substring matching alone does not work on a 30 MB binary. A short handle is a
substring of ordinary identifiers — one four-letter name sits inside a common
crypto suffix present in every curve25519 build, another inside a city name in
the timezone table — and the linker packs unrelated string literals end to end,
so two adjacent config keys can spell a third word across the seam. Three false
alarms, none of them a leak, and a gate that cries wolf gets switched off by
whoever hits it first.

So an identifier-shaped pattern only counts when at least one side of it is NOT
an identifier character. A real leak is a path or a token — `/Users/NAME/`,
`NAME@host`, `/home/NAME_backup` — and every one of those has a boundary. A
pattern welded between identifier characters on both sides is the linker's
doing. Patterns that already contain punctuation (an address, an email) are
matched as they are: they cannot collide with an identifier by accident.

NOTE: no real pattern appears in this file, deliberately. An earlier version of
this docstring quoted the actual examples and this scanner flagged itself — in
a public repository, which is exactly the failure it exists to prevent.
"""

from __future__ import annotations

import os
import re
import sys
import tarfile
import zipfile

IDENT = re.compile(rb"[A-Za-z0-9_]")
RUN = re.compile(rb"[ -~]{4,}")
RUN16_LE = re.compile(rb"(?:[ -~]\x00){4,}")
RUN16_BE = re.compile(rb"(?:\x00[ -~]){4,}")


def load_patterns(text: str) -> tuple[list[str], list[str]]:
    literals: list[str] = []
    allow: list[str] = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("re:"):
            continue
        if line.startswith("allow:"):
            entry = line[len("allow:"):].split("#", 1)[0].strip()
            if entry:
                allow.append(entry)
        else:
            literals.append(line)
    return literals, allow


def hits(blob: bytes, literals: list[str], allow: list[str]) -> list[str]:
    """Every printable run that carries a forbidden string, with context."""
    found: list[str] = []
    # Windows resources and manifests may use UTF-16 even when the binary's
    # diagnostic paths use ASCII. Treat both as the same literal protocol.
    runs = (
        RUN.findall(blob)
        + [match[::2] for match in RUN16_LE.findall(blob)]
        + [match[1::2] for match in RUN16_BE.findall(blob)]
    )
    for run in runs:
        low = run.lower()
        for pattern in literals:
            needle = pattern.lower().encode()
            bare = re.fullmatch(r"[A-Za-z0-9_]+", pattern) is not None
            start = low.find(needle)
            while start != -1:
                end = start + len(needle)
                before = run[start - 1:start] if start else b""
                after = run[end:end + 1]
                glued = bool(IDENT.fullmatch(before)) and bool(IDENT.fullmatch(after))
                if not (bare and glued):
                    text = run.decode("ascii", "replace")
                    if not any(a in text for a in allow):
                        found.append(text[max(0, start - 40):end + 40])
                        # Enough to fail on, and enough to tell an account
                        # name in a path from one baked into a dependency.
                        # A 30 MB library would otherwise print thousands.
                        if len(found) >= 3:
                            return found
                        break
                start = low.find(needle, start + 1)
    return found


def blobs(path: str):
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                if not info.is_dir():
                    yield f"{os.path.basename(path)}:{info.filename}", archive.read(info)
        return
    if tarfile.is_tarfile(path):
        with tarfile.open(path) as archive:
            for member in archive.getmembers():
                if member.isfile():
                    handle = archive.extractfile(member)
                    if handle:
                        yield f"{os.path.basename(path)}:{member.name}", handle.read()
                elif member.issym() or member.islnk():
                    yield f"{os.path.basename(path)}:{member.name}", member.linkname.encode()
        return
    if path.lower().endswith((".zip", ".apk", ".tar", ".tar.gz", ".tgz")):
        raise ValueError("invalid artifact archive")
    with open(path, "rb") as handle:
        yield os.path.basename(path), handle.read()


def main() -> int:
    patterns = os.environ.get("PATTERNS", "")
    if not patterns.strip():
        print("::error::LEAK_PATTERNS is not set — this check would pass by knowing nothing.")
        return 1
    literals, allow = load_patterns(patterns)
    if not literals:
        print("::error::LEAK_PATTERNS defines no literal patterns.")
        return 1
    print(f"patterns: {len(literals)} literal, {len(allow)} allowed")

    root = sys.argv[1] if len(sys.argv) > 1 else "artifacts"
    leaks = 0
    scanned = 0
    for directory, _subdirs, files in os.walk(root):
        for name in sorted(files):
            path = os.path.join(directory, name)
            try:
                for label, blob in blobs(path):
                    scanned += 1
                    count = len(hits(blob, literals, allow)) + len(
                        hits(label.encode(), literals, allow)
                    )
                    if count:
                        # Both context and archive labels can contain the very
                        # identifier we must keep out of public Actions logs.
                        print(f"::error::forbidden data in entry {scanned}")
                        leaks += count
            except (OSError, ValueError, zipfile.BadZipFile, tarfile.TarError):
                print("::error::artifact scan failed; no private details logged")
                return 1
    print(f"scanned {scanned} entries")
    if scanned == 0:
        print("::error::no artifact entries were scanned")
        return 1
    if leaks:
        print(f"::error::{leaks} leak(s) — this must not be published.")
        return 1
    print("OK: nothing forbidden in the artifacts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
