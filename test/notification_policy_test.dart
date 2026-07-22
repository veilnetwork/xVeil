import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/notifications.dart';

void main() {
  group('shouldAlertIncoming (real-time, background-only)', () {
    test('background → alert', () {
      expect(
        shouldAlertIncoming(enabled: true, muted: false, foreground: false),
        isTrue,
      );
    });
    test('foreground → suppress (shown in-app; surfaced on minimize)', () {
      expect(
        shouldAlertIncoming(enabled: true, muted: false, foreground: true),
        isFalse,
      );
    });
    test('muted → never, even backgrounded', () {
      expect(
        shouldAlertIncoming(enabled: true, muted: true, foreground: false),
        isFalse,
      );
    });
    test('notifications disabled → never', () {
      expect(
        shouldAlertIncoming(enabled: false, muted: false, foreground: false),
        isFalse,
      );
    });
  });

  group('shouldAlertOnMinimize (surface unread when leaving the app)', () {
    test('unread, not muted, not the open chat → alert', () {
      expect(
        shouldAlertOnMinimize(
          enabled: true,
          unread: 2,
          muted: false,
          isActive: false,
        ),
        isTrue,
      );
    });
    test('no unread → no alert', () {
      expect(
        shouldAlertOnMinimize(
          enabled: true,
          unread: 0,
          muted: false,
          isActive: false,
        ),
        isFalse,
      );
    });
    test('the chat you were just reading → no alert', () {
      expect(
        shouldAlertOnMinimize(
          enabled: true,
          unread: 3,
          muted: false,
          isActive: true,
        ),
        isFalse,
      );
    });
    test('muted conversation → no alert', () {
      expect(
        shouldAlertOnMinimize(
          enabled: true,
          unread: 3,
          muted: true,
          isActive: false,
        ),
        isFalse,
      );
    });
    test('notifications disabled → no alert', () {
      expect(
        shouldAlertOnMinimize(
          enabled: false,
          unread: 3,
          muted: false,
          isActive: false,
        ),
        isFalse,
      );
    });
  });

  group('notification burst collapse', () {
    test('all conversations replace the same OS notification', () {
      expect(
        notificationIdForIncomingMessage('peer-a'),
        notificationIdForIncomingMessage('group:peer-b'),
      );
    });

    test('newest candidate is selected independent of list order', () {
      final candidates = [
        (name: 'pinned-old', timestamp: 10),
        (name: 'latest-group', timestamp: 30),
        (name: 'middle-chat', timestamp: 20),
      ];

      expect(
        newestByTimestamp(candidates, (candidate) => candidate.timestamp),
        (name: 'latest-group', timestamp: 30),
      );
      expect(newestByTimestamp(<int>[], (value) => value), isNull);
    });
  });

  group('notification payload routes', () {
    test('community publications open the Space publication surface', () {
      expect(notificationRouteForPayload('space:abc'), '/space/abc/posts');
      expect(notificationPayloadSupportsReply('space:abc'), isFalse);
    });

    test('group and direct chat routes retain inline reply support', () {
      expect(notificationRouteForPayload('group:def'), '/group/def');
      expect(notificationRouteForPayload('fedcba'), '/chat/fedcba');
      expect(notificationPayloadSupportsReply('group:def'), isTrue);
      expect(notificationPayloadSupportsReply('fedcba'), isTrue);
      expect(notificationRouteForPayload(''), isNull);
    });
  });
}
