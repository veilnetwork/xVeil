#!/usr/bin/env python3
"""Stage a source-current macOS engine, or remove an earlier optional copy."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

_spec = importlib.util.spec_from_file_location(
    'media_provenance', Path(__file__).with_name('verify-media-provenance.py'))
_media = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_media)


def stage(binary: Path, destination: Path) -> None:
    target = destination / 'libveil_media.dylib'
    if not binary.exists():
        target.unlink(missing_ok=True)
        print('native media absent; removed any earlier bundled engine')
        return
    source = Path(__file__).resolve().parents[1] / 'third_party/veil/flutter/veil_media/src'
    _media.verify(source, binary.with_name(binary.name + '.provenance'), binary)
    subprocess.run(['bash', str(Path(__file__).with_name('check-media-symbols.sh')),
                    str(binary)], check=True)
    destination.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.media-stage-', dir=destination)
    os.close(fd)
    try:
        shutil.copyfile(binary, temporary)
        shutil.copymode(binary, temporary)
        # Bind the staged bytes too, before publishing them into the bundle.
        _media.verify(source, binary.with_name(binary.name + '.provenance'), Path(temporary))
        os.replace(temporary, target)
    finally:
        Path(temporary).unlink(missing_ok=True)
    print('bundled source-current libveil_media.dylib')


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit('usage: stage-macos-media.py <engine> <bundle-frameworks>')
    try:
        stage(Path(sys.argv[1]), Path(sys.argv[2]))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'native media staging failed: {error}', file=sys.stderr)
        print('Rebuild with veil_media/macos/build_veil_media_dylib.sh; '
              'the build must produce the adjacent .provenance record.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
