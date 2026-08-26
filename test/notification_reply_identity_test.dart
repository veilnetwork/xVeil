import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/notifications/opaque_payload.dart';

import 'support/expect_before.dart';

/// A notification outlives the session that posted it.
///
/// Android keeps it until somebody dismisses it, and the identity can change
/// underneath — through the local API, in the background, with nobody looking.
/// The inline reply callback took the CURRENT services, so the message went out
/// from whichever identity happened to be active.
///
/// That is not a wrong-window mistake. It is a message from an identity that
/// never had that conversation, which tells the person on the other end that
/// the two identities are the same device — the one thing a deniable app must
/// not say.
void main() {
  const a = 'aaaa1111';
  const b = 'bbbb2222';
  const chat = 'c0ffee';

  test('a reply goes out from the identity the notification belongs to', () {
    final owners = NotificationOwners()..remember(chat, a);

    expect(owners.mayReplyAs(chat, a), isTrue);
  });

  test('and NOT from one that switched in underneath it', () {
    // The whole scenario: shown while A was active, replied to after the API
    // switched to B.
    final owners = NotificationOwners()..remember(chat, a);

    expect(
      owners.mayReplyAs(chat, b),
      isFalse,
      reason: 'B would have answered a conversation only A ever had',
    );
  });

  test('a payload nobody recorded is refused, not waved through', () {
    // The state after a restart: the notification is still on the screen and
    // nothing in this process knows whose it was. Refusing is the safe
    // direction — the chat still opens, which costs nothing and says nothing.
    final owners = NotificationOwners();

    expect(owners.mayReplyAs(chat, a), isFalse);
  });

  test('and so is a reply with no identity at all', () {
    // Locked, or mid-switch. "Nobody" must not match "nobody".
    final owners = NotificationOwners()..remember(chat, a);

    expect(owners.mayReplyAs(chat, null), isFalse);
    expect(owners.mayReplyAs(chat, ''), isFalse);
  });

  test('recording nothing records nothing', () {
    // A notification shown while the app has no identity — during startup —
    // must not become a wildcard that any later identity matches.
    final owners = NotificationOwners()
      ..remember(chat, null)
      ..remember(chat, '');

    expect(owners.debugLength, 0);
    expect(owners.mayReplyAs(chat, a), isFalse);
  });

  test('the newest owner of a conversation is the one that counts', () {
    // One notification id is reused per conversation. If A and then B both
    // receive in the same chat, the reply belongs to whoever the notification
    // on screen is from — the last one shown.
    final owners = NotificationOwners()
      ..remember(chat, a)
      ..remember(chat, b);

    expect(owners.mayReplyAs(chat, b), isTrue);
    expect(owners.mayReplyAs(chat, a), isFalse);
  });

  test('it does not grow without limit', () {
    // A mailbox replay can post a burst. The oldest falling out means a reply
    // is REFUSED, never misattributed.
    final owners = NotificationOwners(capacity: 4);
    for (var i = 0; i < 10; i++) {
      owners.remember('chat$i', a);
    }

    expect(owners.debugLength, 4);
    expect(owners.mayReplyAs('chat0', a), isFalse, reason: 'the oldest stayed');
    expect(owners.mayReplyAs('chat9', a), isTrue, reason: 'the newest fell out');
  });

  test('clearing leaves nothing attributable', () {
    final owners = NotificationOwners()..remember(chat, a);

    owners.clear();

    expect(owners.mayReplyAs(chat, a), isFalse);
  });

  group('and the app actually uses it', () {
    // Structural, because the reply callback runs inside a live notification
    // plugin response and the send goes through the node. The tests above
    // prove the registry answers correctly; nothing in them proves anybody
    // asks it — which is exactly how a helper ships with no caller.

    test('the reply refuses BEFORE it sends', () {
      final source = File('lib/state/notifications.dart').readAsStringSync();

      // The refusal has to come first, or it is a report and not a guard.
      expectBefore(source, 'mayReplyAs(payload, active)', 'sendText(peer, text)');
      expectBefore(source, 'mayReplyAs(payload, active)', 'svc.postMessage(');
    });

    test('and every notification records whose it is', () {
      final source = File(
        'lib/features/chat/notification_binder.dart',
      ).readAsStringSync();

      expectBefore(
        source,
        'notificationOwnersProvider',
        '.show(',
      );
      expect(
        source,
        contains('.remember(convHex,'),
        reason: 'nothing records the owner, so every reply is unattributable',
      );
    });
  });
}
