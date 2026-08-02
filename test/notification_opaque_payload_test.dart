import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/notifications/opaque_payload.dart';
import 'package:xveil/state/notifications.dart';

/// `NotificationPreview.hidden` neutralised the title and body, so the lock
/// screen said only that something arrived — but the PAYLOAD was handed to the
/// OS unchanged. The system notification database therefore accumulated the
/// conversation ids of everyone the user talks to: outside the hidden volume,
/// readable by anything that dumps it, and surviving the lock.
///
/// A neutral banner over a stored social graph is worse than no hiding at all —
/// it tells the user they are covered while the durable artifact says otherwise.
void main() {
  group('opaque notification payloads', () {
    test('a token carries nothing about the conversation', () {
      final reg = OpaqueNotificationPayloads(random: Random(1));
      const conv = 'beefcafe0123456789abcdef';

      final token = reg.mint(conv);

      expect(token, isNot(contains(conv)));
      for (var i = 4; i <= conv.length; i += 4) {
        expect(
          token,
          isNot(contains(conv.substring(0, i))),
          reason: 'not even a prefix of the conversation id may appear',
        );
      }
      expect(isOpaqueNotificationToken(token), isTrue);
      expect(reg.resolve(token), conv);
    });

    test('the same conversation gets a different token each time', () {
      // A stable token would be a per-conversation identifier by another name,
      // and the OS database would once again hold something that correlates
      // separate alerts to one another.
      final reg = OpaqueNotificationPayloads(random: Random(2));
      const conv = 'aaaa';
      final tokens = {for (var i = 0; i < 20; i++) reg.mint(conv)};
      expect(tokens.length, 20);
    });

    test('resolving does not consume the token', () {
      // The OS can deliver the same tap twice; refusing the second would look
      // like a broken notification.
      final reg = OpaqueNotificationPayloads(random: Random(3));
      final token = reg.mint('conv');
      expect(reg.resolve(token), 'conv');
      expect(reg.resolve(token), 'conv');
    });

    test('clear() makes every token stop resolving', () {
      // This is what lock does. A token that still resolved afterwards would
      // point at a chat the process can no longer open.
      final reg = OpaqueNotificationPayloads(random: Random(4));
      final token = reg.mint('conv');
      reg.clear();
      expect(reg.resolve(token), isNull);
      expect(reg.length, 0);
    });

    test('the table is bounded', () {
      final reg = OpaqueNotificationPayloads(random: Random(5), capacity: 8);
      final tokens = [for (var i = 0; i < 50; i++) reg.mint('conv$i')];
      expect(reg.length, 8);
      // Oldest-first eviction: the newest still resolve, the earliest do not.
      expect(reg.resolve(tokens.last), 'conv49');
      expect(reg.resolve(tokens.first), isNull);
    });

    test('an unknown token is not mistaken for a real payload', () {
      expect(isOpaqueNotificationToken('op:deadbeef'), isTrue);
      // A real conversation hex must never be treated as a token, or resolving
      // would null it out and the tap would go nowhere.
      expect(isOpaqueNotificationToken('beefcafe'), isFalse);
      expect(isOpaqueNotificationToken('group:abcd'), isFalse);
      expect(isOpaqueNotificationToken('space:abcd'), isFalse);
    });
  });

  group('routing still works for real payloads', () {
    test('a resolved conversation routes to its chat', () {
      // The indirection must not change where a tap lands.
      expect(notificationRouteForPayload('beefcafe'), '/chat/beefcafe');
      expect(notificationRouteForPayload('group:abcd'), '/group/abcd');
      expect(notificationRouteForPayload('space:abcd'), '/space/abcd/posts');
    });
  });
}
