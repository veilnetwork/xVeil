// The relay's ceiling, mirrored on the sender — and checked against the real
// thing rather than trusted.
//
// A mailbox PUT is sender-anonymous and therefore fire-and-forget: there is no
// reply path, so when the relay refuses a deposit nobody upstream hears it. It
// refuses for a good reason — a blob a FETCH reply cannot carry back would be
// stored and never fetched, wedging the head of an oldest-first queue — but the
// sender went on reporting the deposit as done. Measured on a two-device stand:
// `stash OK` at the source, `recovered=0` at the sibling, and the truth only in
// a relay log on a server.
//
// So the sender applies the same rule. A mirrored constant is a liability the
// moment it drifts, which is what this reads veil's own source to prevent.

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
    'const\\s+$name\\s*:\\s*usize\\s*=\\s*([^;]+);',
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
  final ipc = '$veil/veil-proto/src/ipc.rs';
  final relay = '$veil/veil-node-runtime/src/builtin/mailbox.rs';

  test('the ceiling we enforce is the ceiling the relay enforces', () {
    final authDeliverMax = _rustConst(ipc, 'MAX_AUTH_DELIVER_MSG_BYTES');
    // `fetch_reply_budget()` is that, less room for the reply's own framing.
    // The 512 is written into the function; if it moves, so must this.
    expect(
      File('$veil/veil-node-runtime/src/builtin/mailbox.rs')
          .readAsStringSync()
          .contains('.saturating_sub(512)'),
      isTrue,
      reason: 'fetch_reply_budget no longer subtracts 512 — re-derive the mirror',
    );
    expect(
      kMailboxBlobMaxBytes,
      authDeliverMax - 512,
      reason: 'a deposit we accept locally would be refused at the relay',
    );
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
  });
}
