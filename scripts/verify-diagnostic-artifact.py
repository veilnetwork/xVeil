#!/usr/bin/env python3
"""Check the compiled Dart snapshot, including each ABI in an APK."""
import sys
import zipfile
from pathlib import Path


def verify(data: bytes, name: str) -> None:
    if b"xveil-diagnostics/1" not in data:
        raise SystemExit(f"{name}: structured diagnostic report missing")
    if b"xveil-diagnostics-enabled/1" not in data:
        raise SystemExit(f"{name}: XVEIL_DIAGNOSTICS instrumentation missing")
    if b"xveil-debug.log" in data:
        raise SystemExit(f"{name}: raw developer log sink unexpectedly enabled")
    print(f"{name}: structured report present, raw log sink absent")


def main() -> None:
    path = Path(sys.argv[1])
    if path.suffix == ".apk":
        with zipfile.ZipFile(path) as archive:
            snapshots = [n for n in archive.namelist()
                         if n.startswith("lib/") and n.endswith("/libapp.so")]
            if not snapshots:
                raise SystemExit("APK contains no Dart snapshots")
            for name in snapshots:
                verify(archive.read(name), name)
    else:
        verify(path.read_bytes(), path.name)


if __name__ == "__main__":
    main()
