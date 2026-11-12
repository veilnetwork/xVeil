#!/usr/bin/env bash
# Source this script before Flutter tests, or run it with GITHUB_ENV set.
# A separate target prevents unrelated SDK builds from supplying the fixture.
set -euo pipefail

case "$(uname -s)" in
  Linux) fixture_library=libveil_fs_test_ffi.so ;;
  Darwin) fixture_library=libveil_fs_test_ffi.dylib ;;
  *) printf '%s\n' 'Unsupported filesystem fixture host' >&2; exit 1 ;;
esac

fixture_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_target="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/veil-fs-fixture.XXXXXXXX")"
CARGO_TARGET_DIR="$fixture_target" cargo build --locked \
  --manifest-path "$fixture_root/third_party/veil/crates/veilclient-ffi/tests/fs_fixture/Cargo.toml"
export XVEIL_FS_TEST_DYLIB="$fixture_target/debug/$fixture_library"
export XVEIL_REQUIRE_FOLDER_FS=1
test -f "$XVEIL_FS_TEST_DYLIB"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'XVEIL_FS_TEST_DYLIB=%s\nXVEIL_REQUIRE_FOLDER_FS=1\n' \
    "$XVEIL_FS_TEST_DYLIB" >> "$GITHUB_ENV"
fi
