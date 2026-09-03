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
    expect(
      owners.mayReplyAs('chat9', a),
      isTrue,
      reason: 'the newest fell out',
    );
  });

  test('clearing leaves nothing attributable', () {
    final owners = NotificationOwners()..remember(chat, a);

    owners.clear();

    expect(owners.mayReplyAs(chat, a), isFalse);
  });

  test('a reply that was sent cannot be sent again', () {
    // The alert is gone — the Android action cancels it — so the entry
    // describes nothing, and an entry that describes nothing is what a stale
    // duplicate of the same alert would ride (report17 XV17-M12).
    final owners = NotificationOwners()..remember(chat, a);

    owners.forget(chat);

    expect(owners.mayReplyAs(chat, a), isFalse);
    expect(owners.debugLength, 0);
  });

  test('forgetting one leaves the others alone', () {
    // Vacuity guard: a `forget` that emptied the map would refuse every other
    // alert on the screen.
    final owners = NotificationOwners()
      ..remember(chat, a)
      ..remember('other', a);

    owners.forget(chat);

    expect(owners.mayReplyAs('other', a), isTrue);
  });

  group('and the app actually uses it', () {
    // Structural, because the reply callback runs inside a live notification
    // plugin response and the send goes through the node. The tests above
    // prove the registry answers correctly; nothing in them proves anybody
    // asks it — which is exactly how a helper ships with no caller.

    test('the reply refuses BEFORE it sends', () {
      final source = File('lib/state/notifications.dart').readAsStringSync();

      // The refusal has to come first, or it is a report and not a guard.
      expectBefore(
        source,
        'mayReplyAs(payload, active)',
        'sendText(peer, text)',
      );
      expectBefore(source, 'mayReplyAs(payload, active)', 'svc.postMessage(');
    });

    test('and every notification records whose it is', () {
      final source = File(
        'lib/features/chat/notification_binder.dart',
      ).readAsStringSync();

      expectBefore(source, 'notificationOwnersProvider', '.show(');
      expect(
        source,
        contains('owners.remember(convHex,'),
        reason: 'nothing records the owner, so every reply is unattributable',
      );
    });

    test('but only once the alert is actually on the screen', () {
      // `show` has two silent failure paths — a service that is not ready and
      // a plugin that threw. Recording the owner first meant a show that never
      // happened still moved it, while the PREVIOUS alert, belonging to
      // another identity, was still on screen with its inline reply live
      // (report17 XV17-M12).
      final source = File(
        'lib/features/chat/notification_binder.dart',
      ).readAsStringSync();

      expectBefore(source, '.show(', 'owners.remember(convHex,');
      // The shape moved when the post gained an identity check (XV-N1): a
      // failed post now returns early rather than guarding one statement.
      // What must hold is the same either way — nothing between the post and
      // the record may run when the post did not happen.
      final at = source.indexOf('owners.remember(convHex,');
      final between = source.substring(source.indexOf('.show(', 0), at);
      expect(
        RegExp(
          r'if \(!posted\) return;|if \(posted\) owners\.remember\(',
        ).hasMatch(between),
        isTrue,
        reason: 'the owner moves for an alert that was never posted',
      );
    });

    test('and a reply that goes out uses its attribution up', () {
      // The alert is cancelled by the Android action, so the entry describes
      // nothing afterwards — and an entry that describes nothing is what a
      // stale duplicate of the same alert would ride. Consumed BEFORE the
      // send, so an exception on the way out cannot leave it behind.
      final source = File('lib/state/notifications.dart').readAsStringSync();

      expectBefore(source, 'forget(payload)', 'sendText(peer, text)');
      expectBefore(source, 'forget(payload)', 'svc.postMessage(');
    });

    test('a switch drops the alerts before it re-points the view', () {
      // Lock has cleared the shade all along; a SWITCH did not, so alerts
      // posted by the identity being left behind stayed on screen with their
      // replies live — and the owner map that decides who may answer them
      // survived too, in a class whose `clear` production never called.
      final source = File('lib/state/app_controller.dart').readAsStringSync();

      expect(
        source,
        contains('notificationOwnersProvider).clear()'),
        reason: 'the owner map outlives every session in the process',
      );
      expectBefore(
        source,
        '_dropPostedNotifications();',
        'realStackProvider.notifier).state = stack',
      );
    });
  });
}
