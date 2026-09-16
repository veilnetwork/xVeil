import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  /// A relay is written down before the question goes out, not after.
  ///
  /// `asked` is what the reply handler checks before accepting an answer, and
  /// it was filled once the send RETURNED. The send is a real await — the
  /// request leaves inside it — so a relay that answers quickly could have its
  /// reply delivered while the drain had not yet written it down, and the
  /// handler dropped the answer as unsolicited. The pass then waited out its
  /// timeout for something it had already been given (report27 X34).
  ///
  /// Structural, and deliberately: driving it means delivering a reply between
  /// two statements of another isolate's send. A guard at the source says the
  /// same thing without a coin flip — the same choice this repository has made
  /// for every other ordering race it could not stage.
  test('the drain marks a relay asked before it sends', () {
    final src = File(
      'lib/data/transport/veil_mailbox_network.dart',
    ).readAsStringSync();

    // The one send site, bounded to its own try block.
    final at = src.indexOf('final wasAsked = asked.add(askedHex);');
    expect(
      at,
      greaterThan(0),
      reason:
          'the drain no longer records the relay before sending — a reply '
          'that arrives first is dropped as unsolicited',
    );
    final send = src.indexOf(
      'sendAnonymousAuthenticatedDirectWithReply(',
      at,
    );
    expect(send, greaterThan(at), reason: 'the send moved away from the mark');

    // And nothing marks it again afterwards, which would be the old shape
    // left in place beside the new one.
    final tail = src.substring(send);
    expect(
      tail.contains('asked.add(NodeId(relayId).hex)'),
      isFalse,
      reason: 'the post-send mark is back beside the pre-send one',
    );

    // A send that FAILED must take the mark back, or a relay that never heard
    // the question counts as one that did.
    final rollback = src.indexOf('if (wasAsked) asked.remove(askedHex);', send);
    expect(
      rollback,
      greaterThan(send),
      reason:
          'a failed send leaves the relay marked as asked, so the drain waits '
          'for an answer nobody was asked for',
    );
  });
}
