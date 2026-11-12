#!/usr/bin/env python3
"""Load bundled native libraries in an isolated process without opening the app."""
from __future__ import annotations

import ctypes
from pathlib import Path
import sys


LIBRARIES = (
    "libveilclient_ffi.dylib", "libhidden_volume_ffi.dylib", "libveil_media.dylib",
    "libveil_whisper.dylib", "libveil_translate.dylib",
)


def check(app: Path) -> int:
    if sys.platform != "darwin":
        raise RuntimeError("native macOS load checks require a Darwin host")
    app = app.resolve(strict=True)
    frameworks = app / "Contents/Frameworks"
    handles = []
    for index, name in enumerate(LIBRARIES):
        library = frameworks / name
        if index >= 2 and not library.exists():
            continue
        resolved = library.resolve(strict=True)
        if not resolved.is_relative_to(app):
            raise ValueError("native library points outside the application")
        # The media shim resolves the SDK's transport functions globally.
        # Keep each handle alive until all optional libraries are loaded too.
        handles.append(ctypes.CDLL(str(resolved), mode=ctypes.RTLD_GLOBAL))
    return len(handles)


if __name__ == "__main__":
    try:
        count = check(Path(sys.argv[1]))
    except (OSError, ValueError, RuntimeError) as error:
        print(f"native macOS load check failed: {error}", file=sys.stderr)
        raise SystemExit(1)
    print(f"OK: {count} bundled native libraries loaded; no app or audio capture started")
