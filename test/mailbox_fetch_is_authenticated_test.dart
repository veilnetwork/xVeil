import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The mailbox FETCH must be an AUTHENTICATED send, and that is not a style
/// preference — it is what decides WHOSE mailbox the relay opens.
///
/// The relay serves `fetch_skipping(src_node_id, …)`, where `src_node_id` is
/// whatever the delivery path proved about the asker. On the signed path the
/// node reports the sender's IDENTITY (`auth.sender_node_id`); on a plain
/// session-carried message it reports the SESSION PEER, which is the device's
/// transport id. A deposit is addressed to the contact's identity — the address
/// the invite carries and the address the receiver's rendezvous ad now names —
/// so a fetch that asked as the device would open an empty box and mail would
/// pile up unread at the relay with nothing in any log to say why.
///
/// This is the one step of that chain a Dart change could flip silently, so it
/// is pinned here. The rest of the chain is held on the veil side:
/// `network_fetch_replies_with_authenticated_receivers_blobs` (the relay serves
/// the asker's own box) and `epic482_5_end_to_end_authenticated_rendezvous_flow`
/// (a signed delivery reports the sender's sovereign node_id).
void main() {
  test('every mailbox FETCH goes out on an authenticated send', () {
    final source = File(
      'lib/data/transport/veil_mailbox_network.dart',
    ).readAsStringSync();

    final calls = RegExp(r'_fetchApp\.(\w+)\(').allMatches(source).toList();
    expect(
      calls,
      isNotEmpty,
      reason: 'the fetch client moved — this guard now watches nothing',
    );

    var sawFetchSend = false;
    for (var i = 0; i < calls.length; i++) {
      final name = calls[i].group(1)!;
      final end = i + 1 < calls.length ? calls[i + 1].start : source.length;
      final body = source.substring(calls[i].end, end);
      if (!body.contains('kMailboxFetchEndpointId')) continue;
      sawFetchSend = true;
      expect(
        name.startsWith('sendAnonymousAuthenticated'),
        isTrue,
        reason:
            'the FETCH went out through _fetchApp.$name, which does not prove '
            'the asker to the relay — it would open the DEVICE\'s box, and the '
            'mail is addressed to the identity',
      );
    }
    expect(
      sawFetchSend,
      isTrue,
      reason: 'no send targets the fetch endpoint — the guard is vacuous',
    );
  });
}
