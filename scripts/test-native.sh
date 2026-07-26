#!/usr/bin/env bash
# Run the test/native/ checks that need only locally built libraries.
#
# WHY: those tests are env-gated, so a plain `flutter test` skips them and says
# so in one line nobody reads. That reads as "hardware-dependent", but most of
# them are not: they need the same dylibs build-native.sh already produces, and
# they cover the parts the fakes cannot — real BIP-39, identity provisioning,
# the external blob store, cloud-document crypto, and three real nodes forming
# a holder quorum. Passing on fakes says nothing about any of it.
#
# What this does NOT run, and why (each needs something outside this machine):
#   * mailbox_*/relay_*/rendezvous_*/onion_* — a running veil node whose IPC
#     socket path and node id are passed in (XVEIL_TEST_SOCK_*, XVEIL_*_NODE_ID);
#     see scripts/dev-mailbox-pair.sh and friends, which stand those up.
#   * *_testnet_*                            — the production seeds + obfs4 PSK.
#   * veil_media_screen_sources_live         — a real screen and its TCC grant.
#   * headless_runtime_live                  — HEADLESS_LIVE, spawns a daemon.
#
#   scripts/test-native.sh [extra flutter test args...]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Prefer the dylibs bundled into a built .app (they are the ones the product
# actually loads); fall back to the cargo target dir for a bare checkout.
find_lib() {
  local name="$1" candidate
  for candidate in \
    "$ROOT/build/macos/Build/Products/Debug/xveil.app/Contents/Frameworks/$name" \
    "$ROOT/build/macos/Build/Products/Release/xveil.app/Contents/Frameworks/$name" \
    "$ROOT/third_party/veil/target/debug/$name" \
    "$ROOT/third_party/veil/target/release/$name" \
    "$ROOT/third_party/hidden-volume/target/debug/$name" \
    "$ROOT/third_party/hidden-volume/target/release/$name"
  do
    [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

case "$(uname -s)" in
  Darwin) EXT="dylib" ;;
  *)      EXT="so" ;;
esac

VEIL_LIB="$(find_lib "libveilclient_ffi.$EXT")" || {
  echo "libveilclient_ffi.$EXT not found — run scripts/build-native.sh first" >&2
  exit 1
}
HV_LIB="$(find_lib "libhidden_volume_ffi.$EXT")" || {
  echo "libhidden_volume_ffi.$EXT not found — run scripts/build-native.sh first" >&2
  exit 1
}

echo "veilclient  : $VEIL_LIB"
echo "hiddenvolume: $HV_LIB"

export VEIL_FFI_DYLIB="$VEIL_LIB"
export HIDDEN_VOLUME_FFI_DYLIB="$HV_LIB"

# group_service_test carries the XVSB/XVRC cases behind the same gate, so it is
# not a native-only file but it IS part of what the gate hides.
flutter test \
  test/native/veil_bip39_live_test.dart \
  test/native/identity_origin_live_test.dart \
  test/native/external_blob_store_native_test.dart \
  test/native/cloud_document_crypto_live_test.dart \
  test/group_service_test.dart \
  "$@"

# Separately, and last: this one spawns three real nodes on loopback and waits
# up to 90s for a two-holder quorum. Run beside the rest it loses that race on
# a busy machine and reports a timeout that has nothing to do with the code —
# measured here as pass in ~10s alone, timeout alongside 175 other tests.
echo
echo "== three real nodes (serialised: it competes for CPU with nothing) =="
PUBLIC_SPACE_DISCOVERY_LIVE=1 exec flutter test \
  test/native/public_space_discovery_live_test.dart \
  "$@"
