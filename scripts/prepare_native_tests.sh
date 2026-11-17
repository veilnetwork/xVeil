#!/usr/bin/env bash
# Source before Flutter tests, or run with GITHUB_ENV set. These are isolated
# Linux CI test libraries, not release artifacts. Fresh per-checkout targets
# prevent a cached library from silently standing in for the selected source.
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
  printf '%s\n' 'Native CI preparation requires a Linux runner' >&2
  exit 1
fi

native_test_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
native_test_temp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
native_test_hv_target="$(mktemp -d "$native_test_temp/xveil-hv-tests.XXXXXXXX")"
native_test_veil_target="$(mktemp -d "$native_test_temp/xveil-veil-tests.XXXXXXXX")"

CARGO_TARGET_DIR="$native_test_hv_target" cargo build --release --locked \
  --manifest-path "$native_test_root/third_party/hidden-volume/Cargo.toml" \
  -p hidden-volume-ffi
CARGO_TARGET_DIR="$native_test_veil_target" cargo build --release --locked \
  --manifest-path "$native_test_root/third_party/veil/Cargo.toml" \
  -p veilclient-ffi \
  --features node-embedded,packet-tunnel,allow-empty-seeds,test-low-difficulty

export XVEIL_HV_DYLIB="$native_test_hv_target/release/libhidden_volume_ffi.so"
export VEIL_FFI_DYLIB="$native_test_veil_target/release/libveilclient_ffi.so"

# Actually load both libraries and check entrypoints used by storage workers
# and the embedded node. File presence alone misses wrong/stale build outputs.
python3 - <<'PY'
import ctypes
import hashlib
import os
from pathlib import Path

for variable, symbols in {
    'XVEIL_HV_DYLIB': [
        'uniffi_hidden_volume_ffi_fn_constructor_spacehandle_open',
        'uniffi_hidden_volume_ffi_fn_constructor_spacehandle_create_with_padding',
    ],
    'VEIL_FFI_DYLIB': ['veil_abi_contract_hash', 'veil_config_init'],
}.items():
    path = Path(os.environ[variable])
    if not path.is_absolute() or not path.is_file():
        raise RuntimeError(f'{variable}: native test library missing')
    library = ctypes.CDLL(str(path))
    for symbol in symbols:
        getattr(library, symbol)
    print(f'{variable}: load/entrypoints OK; sha256={hashlib.sha256(path.read_bytes()).hexdigest()}')
PY

if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'XVEIL_HV_DYLIB=%s\nVEIL_FFI_DYLIB=%s\n' \
    "$XVEIL_HV_DYLIB" "$VEIL_FFI_DYLIB" >> "$GITHUB_ENV"
fi
