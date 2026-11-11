#!/usr/bin/env python3
"""Require the prebuilt engine to contain the checked-out native media fixes.

An unchanged ABI cannot detect an old implementation. Producers record a digest
of the native source tree alongside the binary SHA; release consumers check both.
CRLF is normalized to LF so Windows checkout policy does not change the digest.
Paths are ordered by their case-sensitive POSIX spelling on every platform.
"""
import argparse
import hashlib
import importlib.util
from pathlib import Path
import re


_helper = Path(__file__).resolve().parents[1] / 'third_party/veil/flutter/veil_media/source_provenance.py'
_spec = importlib.util.spec_from_file_location('native_media_provenance', _helper)
_native = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_native)
source_digest = _native.source_digest


def verify(source: Path, provenance: Path, binary: Path | None = None) -> None:
    rows = [line.split(':', 1)[1].strip()
            for line in provenance.read_text(encoding='utf-8').splitlines()
            if line.startswith('media-source-sha256:')]
    if len(rows) != 1 or not re.fullmatch('[0-9a-f]{64}', rows[0]):
        raise ValueError('engine provenance needs exactly one media-source-sha256')
    if rows[0] != source_digest(source):
        raise ValueError('engine predates or differs from the native media source; rebuild and repin it')
    if binary is not None:
        hashes = [line.split(':', 1)[1].strip()
                  for line in provenance.read_text(encoding='utf-8').splitlines()
                  if line.startswith('sha256:')]
        if len(hashes) != 1 or not re.fullmatch('[0-9a-f]{64}', hashes[0]):
            raise ValueError('engine provenance needs exactly one binary sha256')
        if hashlib.sha256(binary.read_bytes()).hexdigest() != hashes[0]:
            raise ValueError('engine binary differs from its provenance; rebuild it')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provenance', type=Path)
    parser.add_argument('--binary', type=Path)
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1] / 'third_party/veil/flutter/veil_media/src'
    try:
        if args.provenance:
            verify(source, args.provenance, args.binary)
            print('OK: native media source matches the engine provenance')
        elif args.binary:
            parser.error('--binary requires --provenance')
        else:
            print(source_digest(source))
    except (OSError, ValueError) as error:
        parser.exit(1, f'engine provenance: {error}\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
