#!/usr/bin/env python3
"""Check the selected native storage library against the current Dart bindings.

Only resolves bound exports and calls argument-free ABI/version checksums.
Never opens a container or creates storage state. The caller must isolate native
loading in a child process, as the macOS packaging gate already does.
"""
from __future__ import annotations

import argparse
import ctypes
from dataclasses import dataclass
from pathlib import Path
import re
import sys


BINDINGS = (Path(__file__).resolve().parents[1] / 'third_party/hidden-volume/'
            'experimental/flutter_plugin/hidden_volume/lib/src/bindings.dart')
CONTRACT_SYMBOL = 'ffi_hidden_volume_ffi_uniffi_contract_version'
FN_PREFIX = 'uniffi_hidden_volume_ffi_fn_'
CHECKSUM_PREFIX = 'uniffi_hidden_volume_ffi_checksum_'


class StorageAbiFailure(ValueError):
    """Fixed diagnostic categories, with no paths or native error text."""


@dataclass(frozen=True)
class Contract:
    version: int
    checksums: dict[str, int]
    symbols: frozenset[str]


def read_contract(bindings: Path = BINDINGS) -> Contract:
    try:
        source = bindings.read_text(encoding='utf-8')
    except OSError:
        raise StorageAbiFailure('current storage bindings unavailable') from None
    versions = re.findall(r'const int _expectedContractVersion\s*=\s*(\d+)\s*;', source)
    blocks = re.findall(r'// BEGIN GENERATED CHECKSUMS[^\n]*\n(.*?)'
                        r'// END GENERATED CHECKSUMS', source, re.S)
    if len(versions) != 1 or len(blocks) != 1:
        raise StorageAbiFailure('invalid storage ABI metadata')
    table = re.fullmatch(
        r'\s*const\s+Map<String,\s*int>\s+_methodChecksums\s*=\s*'
        r'<String,\s*int>\s*\{(.*?)\};\s*', blocks[0], re.S)
    if table is None:
        raise StorageAbiFailure('invalid storage checksum table')
    entry = r"^\s*'(" + CHECKSUM_PREFIX + r"[a-z0-9_]+)'\s*:\s*(\d+),\s*$"
    pairs = re.findall(entry, table[1], re.M)
    if re.sub(entry, '', table[1], flags=re.M).strip():
        raise StorageAbiFailure('nonliteral storage checksum metadata')
    checksums = {name: int(value) for name, value in pairs}
    functions = set(re.findall(r"'(" + FN_PREFIX + r"[a-z0-9_]+)'", source))
    expected = {CHECKSUM_PREFIX + name[len(FN_PREFIX):] for name in functions
                if not name[len(FN_PREFIX):].startswith(('clone_', 'free_'))}
    if (not functions or not checksums or len(checksums) != len(pairs)
            or set(checksums) != expected
            or any(value > 65535 for value in checksums.values())):
        raise StorageAbiFailure('storage checksum inventory does not match bindings')
    symbols = frozenset(re.findall(r"'((?:ffi|uniffi)_hidden_volume_ffi_[a-z0-9_]+)'", source))
    if CONTRACT_SYMBOL not in symbols:
        raise StorageAbiFailure('storage contract version lookup missing')
    return Contract(int(versions[0]), checksums, symbols)


def verify_loaded(library, contract: Contract) -> int:
    functions = {}
    for name in sorted(contract.symbols):
        try:
            functions[name] = getattr(library, name)
        except AttributeError:
            # Symbol names are public API, but even the selected file path
            # and the loader's native error text stay out of this report.
            raise StorageAbiFailure('storage library lacks required FFI exports') from None
    version = functions[CONTRACT_SYMBOL]
    version.argtypes = []
    version.restype = ctypes.c_uint32
    if version() != contract.version:
        raise StorageAbiFailure('storage UniFFI contract version mismatch')
    for name, expected in contract.checksums.items():
        method = functions[name]
        method.argtypes = []
        method.restype = ctypes.c_uint16
        if method() != expected:
            raise StorageAbiFailure('storage method checksum mismatch')
    return len(contract.checksums)


def check_library(library: Path, bindings: Path = BINDINGS) -> int:
    contract = read_contract(bindings)
    try:
        handle = ctypes.CDLL(str(library.resolve(strict=True)))
    except (OSError, RuntimeError):
        raise StorageAbiFailure('storage native library cannot be loaded') from None
    return verify_loaded(handle, contract)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('library', type=Path)
    parser.add_argument('--bindings', type=Path, default=BINDINGS)
    args = parser.parse_args()
    try:
        count = check_library(args.library, args.bindings)
    except StorageAbiFailure as error:
        print(f'storage ABI check failed: {error}', file=sys.stderr)
        return 1
    print(f'OK: storage contract, bound exports and {count} method checksums match')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
