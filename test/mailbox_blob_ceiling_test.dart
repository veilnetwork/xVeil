// The relay's ceiling, mirrored on the sender — and checked against the real
// thing rather than trusted.
//
// A mailbox PUT is sender-anonymous and therefore fire-and-forget: there is no
// reply path, so when the relay refuses a deposit nobody upstream hears it. The
// sender goes on reporting the deposit as done, so it applies the same rule
// itself. A mirrored constant is a liability the moment it drifts, which is
// what this reads veil's own source to prevent.
//
// The ceiling MOVED, and the reason is worth keeping. It used to be one FETCH
// reply's worth, because a reply was the only way out of the store and a blob
// nobody could fetch wedged the head of an oldest-first queue. But a blob
// carries one ML-KEM envelope PER RECIPIENT DEVICE, so its weight follows the
// identity rather than the message: a 2874-byte frame sealed to 13937 bytes for
// an identity with two other devices, and every deposit to it was refused —
// nothing the app could send was small enough. The relay now announces such a
// blob and serves it a window at a time, so the deposit cap is the store's own
// again.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_mailbox_network.dart';

/// Pull `name`'s integer definition out of a Rust source file. Deliberately
/// narrow: it matches the `const NAME: usize = <expr>;` form these two use, and
/// evaluates the simple sums they are written as.
int _rustConst(String path, String name) {
  final src = File(path).readAsStringSync();
  final m = RegExp(
    'const\\s+$name\\s*:\\s*(?:usize|u64)\\s*=\\s*([^;]+);',
  ).firstMatch(src);
  expect(m, isNotNull, reason: '$name is gone from $path — the mirror is blind');
  final expr = m!.group(1)!.replaceAll(RegExp(r'\s|_'), '');
  return expr
      .split('+')
      .map((t) => t.contains('*')
          ? t.split('*').map(int.parse).reduce((a, b) => a * b)
          : int.parse(t))
      .reduce((a, b) => a + b);
}

void main() {
  const veil = 'third_party/veil/crates';
  final relay = '$veil/veil-node-runtime/src/builtin/mailbox.rs';

  test('the ceiling we enforce is the ceiling the relay enforces', () {
    expect(
      kMailboxBlobMaxBytes,
      _rustConst('$veil/veil-mailbox/src/lib.rs', 'MAX_BLOB_BYTES'),
      reason: 'a deposit we accept locally would be refused at the relay',
    );
  });

  // The gate whose removal is the point of the slice endpoint. While it stood,
  // the relay refused at the door any deposit larger than one reply — which for
  // a multi-device identity is every deposit. If it comes back, the sender's
  // higher ceiling becomes a lie and deposits vanish silently again.
  test('the relay no longer refuses a deposit for being unfetchable', () {
    final src = File(relay).readAsStringSync();
    // The SIZE gate specifically, by the phrase only it used. "PUT rejected"
    // on its own also covers quotas and capability tokens, which are supposed
    // to refuse.
    expect(
      src.contains('would be permanently unfetchable'),
      isFalse,
      reason: 'the PUT size gate is back — deposits to a multi-device identity '
          'will be refused at the door again',
    );
  });

  // Announced, not purged. The relay used to DELETE a blob it could not fit in
  // a reply; a receiver that waits for mail the relay threw away waits forever.
  test('an oversized blob is announced rather than deleted', () {
    final src = File(relay).readAsStringSync();
    expect(src.contains('announcing oversized blob'), isTrue);
    expect(
      src.contains('purged oversized blob'),
      isFalse,
      reason: 'the relay deletes mail it could serve in windows',
    );
  });

  // Two numbers on two sides of an onion round trip. Disagree and the request
  // reaches an endpoint nothing is bound to, which is indistinguishable from a
  // relay that is simply older — so the drain would look merely unlucky.
  test('the slice endpoint id is the one veil binds', () {
    final src =
        File('$veil/veil-mailbox/src/service.rs').readAsStringSync();
    final m = RegExp(r'MAILBOX_SLICE_ENDPOINT_ID:\s*u32\s*=\s*(\d+)')
        .firstMatch(src);
    expect(m, isNotNull, reason: 'veil no longer declares a slice endpoint');
    expect(kMailboxSliceEndpointId, int.parse(m!.group(1)!));
  });

  test('the per-blob header we charge is the one the relay charges', () {
    expect(
      kMailboxPerBlobWireHeaderBytes,
      _rustConst(relay, 'PER_BLOB_WIRE_HDR'),
      reason: 'off-by-a-header is enough to have a deposit refused',
    );
  });

  // The error carries the numbers, because the useful question after seeing it
  // is "by how much", and a bare type name cannot answer that.
  test('the refusal says what was too big and for whom', () {
    final receiver = NodeId(Uint8List.fromList(List.filled(32, 0xB1)));
    final e = MailboxBlobTooLarge(6976, receiver).toString();
    expect(e, contains('6976'));
    expect(e, contains('$kMailboxBlobMaxBytes'));
    expect(e, contains('b1b1b1b1'));
  });
}
