#!/usr/bin/env python3
"""Require the prebuilt engine to contain the checked-out native media fixes.

An unchanged ABI cannot detect an old implementation. Producers record a digest
of the native source tree alongside the binary SHA; release consumers check both.
CRLF is normalized to LF so Windows checkout policy does not change the digest.
Paths are ordered by their case-sensitive POSIX spelling on every platform.
"""
import argparse
import hashlib
from pathlib import Path
import re


def source_digest(source: Path) -> str:
    files = sorted((p for p in source.rglob('*') if p.is_file()),
                   key=lambda p: p.relative_to(source).as_posix())
    if not files:
        raise ValueError('native media source tree is empty')
    digest = hashlib.sha256(b'xveil-media-source-v1\0')
    for path in files:
        if path.is_symlink():
            raise ValueError('native media source must not contain symlinks')
        name = path.relative_to(source).as_posix().encode('utf-8')
        data = path.read_bytes().replace(b'\r\n', b'\n')
        digest.update(len(name).to_bytes(8, 'big'))
        digest.update(name)
        digest.update(len(data).to_bytes(8, 'big'))
        digest.update(data)
    return digest.hexdigest()


def verify(source: Path, provenance: Path) -> None:
    rows = [line.split(':', 1)[1].strip()
            for line in provenance.read_text(encoding='utf-8').splitlines()
            if line.startswith('media-source-sha256:')]
    if len(rows) != 1 or not re.fullmatch('[0-9a-f]{64}', rows[0]):
        raise ValueError('engine provenance needs exactly one media-source-sha256')
    if rows[0] != source_digest(source):
        raise ValueError('engine predates or differs from the native media source; rebuild and repin it')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provenance', type=Path)
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1] / 'third_party/veil/flutter/veil_media/src'
    try:
        if args.provenance:
            verify(source, args.provenance)
            print('OK: native media source matches the engine provenance')
        else:
            print(source_digest(source))
    except (OSError, ValueError) as error:
        parser.exit(1, f'engine provenance: {error}\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
