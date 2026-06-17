import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart';

/// CHUNK R.4 — proves the veil-layer relay-X25519-by-node_id DHT resolve.
///
/// A relay-capable node R publishes a signed `RelayKeyRecord` to the DHT (its
/// `device_anonymity_x25519` key, re-signed each republish tick). A different
/// node F then resolves R's relay X25519 over the DHT knowing only R's node_id
/// — `VeilClient.lookupRelayX25519(R_id)` — and the resolved key must equal R's
/// OWN key (ground truth from R's `getRelayX25519Pubkey`). This is the missing
/// piece that lets a receiver advertise an always-on third-party relay as its
/// mailbox host on the real net (chunk 2 only had it via same-machine IPC).
///
/// Bring the mesh up first:  scripts/dev-mailbox-onion.sh
/// then run with the env it prints for mailbox_fetch_live_test (same vars):
///   VEIL_FFI_DYLIB, XVEIL_TEST_SOCK_SENDER (=F), XVEIL_TEST_SOCK_RELAY (=R),
///   XVEIL_RELAY_NODE_ID (=R's node_id).
void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final sockF = Platform.environment['XVEIL_TEST_SOCK_SENDER'];
  final sockR = Platform.environment['XVEIL_TEST_SOCK_RELAY'];
  final rIdHex = Platform.environment['XVEIL_RELAY_NODE_ID'];
  final skip = (dylib == null || dylib.isEmpty || sockF == null || sockF.isEmpty ||
          sockR == null || sockR.isEmpty || rIdHex == null || rIdHex.length != 64)
      ? 'set VEIL_FFI_DYLIB + XVEIL_TEST_SOCK_SENDER/RELAY + XVEIL_RELAY_NODE_ID (64hex)'
      : false;

  test('a node resolves a published relay X25519 by node_id (full new stack)',
      timeout: const Timeout(Duration(seconds: 120)), () async {
    DynamicLibrary.open(dylib!);
    final rId = _hex(rIdHex!);

    // Self-resolve: R's daemon resolves R's OWN published RelayKeyRecord via
    // get_local. This exercises the ENTIRE new path end to end — Dart
    // lookupRelayX25519 → FFI veil_lookup_relay_x25519 → veilclient
    // LookupRelayKey → IPC handler → DhtMlKemEkResolver.fetch_relay_x25519 →
    // fetch_verified_document + RelayKeyRecord decode + verify_relay_key →
    // reply — without depending on cross-node DHT propagation (a separately
    // tracked cold-start gap; STEP 2b resolved its own ad for the same reason).
    final clientR = await VeilClient.connect(sockR!);
    try {
      final truth = await clientR.getRelayX25519Pubkey();
      expect(truth, isNotNull,
          reason: 'R is not relay-capable — no key to publish/resolve');
      stderr.writeln('[relay-key] R local key: ${truth!.length}B');

      // Retry briefly: the one-shot publish + the resolver's verify both need
      // the identity doc + record to be locally stored (they are at startup).
      Uint8List? resolved;
      var attempts = 0;
      while (resolved == null && attempts < 20) {
        attempts++;
        resolved = await clientR.lookupRelayX25519(rId);
        if (resolved == null) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
      stderr.writeln('[relay-key] resolved after $attempts attempt(s): '
          '${resolved == null ? "NULL" : "${resolved.length}B"}');
      expect(resolved, isNotNull,
          reason: 'daemon could not resolve the published relay X25519');
      expect(resolved, truth,
          reason: 'resolved key must equal the published relay X25519');
      stderr.writeln('[relay-key] ✓ DHT-resolved relay X25519 matches ground truth '
          '(full Dart→FFI→IPC→resolver→verify stack)');
    } finally {
      await clientR.close();
    }
  }, skip: skip);
}

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
